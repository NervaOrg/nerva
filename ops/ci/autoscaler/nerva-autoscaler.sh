#!/usr/bin/env bash
# Runs on the CI box, as root: on-demand Hetzner Cloud agents for Woodpecker (decision O6; ops/ci/README.md,
# "Cloud agents"). The official woodpecker-ci/autoscaler runs in a container (pinned by digest in lib.sh),
# creates a dedicated-vCPU server from the nightly snapshot when a `tier: cloud` workflow waits, and
# deletes it after AS_IDLE minutes with no work (and never more than AS_MAX at once).
#
#   Install (after `scp -r ops/ci root@BOX:`, from ~ on the box; needs docker, curl, jq, systemd):
#     NERVA_AS_SERVER=https://ci.example.org bash ci/autoscaler/nerva-autoscaler.sh install
#   Copies ops/ci/'s docker/, io_uring_probe.sh, nerva-woodpecker.sh and autoscaler/ (all the snapshot build
#   needs) to /usr/local/lib/nerva-ci/ci/, writes /etc/nerva-ci/autoscaler.conf (no secrets;
#   an existing line is kept unless its NERVA_AS_* variable is given), installs the systemd units and
#   enables the nightly snapshot timer. Run it again to change a setting. It checks the two secret
#   files (below) and that the pinned autoscaler has the flags this script passes (NRV-E1240).
#   Settings (variables, default): NERVA_AS_SERVER (required), NERVA_AS_GRPC (CI_GRPC_HOST:443 from
#   /etc/woodpecker/ci.env: remote agents reach the server through Caddy with TLS, never on port 9000),
#   NERVA_AS_LOCATION (fsn1: use the box's), NERVA_AS_SERVER_TYPE (ccx33; or ccx43), NERVA_AS_MAX (4,
#   the hard cap on servers, 1 to 16), NERVA_AS_IDLE (10m).
#   `check`  validates the settings, the secrets and the snapshot, and counts the servers (NRV-W1208).
#   `status` prints the settings, the snapshot and the servers that exist now.
#   `run`    is what the service runs: starts the autoscaler container (exec, in the foreground).
#
# Secrets, root's, mode 0600, one line each, never in the repository, argv, a unit file or a log:
#   /etc/nerva-ci/hcloud.token       a Read & Write API token of a Hetzner project that holds only CI.
#   /etc/nerva-ci/woodpecker.token   a Woodpecker personal access token of an admin (the autoscaler uses
#                                    it to register agents; each cloud server gets its own agent token).
# The container gets them as read-only mounted files (the autoscaler's *_FILE settings), not as variables.
#
# Where it looks, for ci/autoscaler_test.sh (which runs it with stubs): NERVA_CI_ETC (/etc/nerva-ci),
# NERVA_AS_LIB (/usr/local/lib/nerva-ci), NERVA_AS_UNITS (/etc/systemd/system), NERVA_AS_NO_SYSTEMD=1
# (do not run systemctl), NERVA_WP_ENV (/etc/woodpecker/ci.env) and NERVA_HCLOUD_API.
# shellcheck disable=SC2154,SC2034 # etc, tool and the pins come from lib.sh (not followed: no -x)
set -euo pipefail

tool=nerva-autoscaler
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
lib="${NERVA_AS_LIB:-/usr/local/lib/nerva-ci}"
units="${NERVA_AS_UNITS:-/etc/systemd/system}"

need_tools() {
    local t
    for t in "$@"; do command -v "$t" > /dev/null || fail "NRV-E1239: $t is not installed: install it first (apt-get install $t)"; done
}

snapshot_id() { # the numeric id the nightly build wrote; NRV-E1243 when there is none yet
    local id=""
    [ ! -f "$etc/autoscaler.image" ] || id=$(tr -d '[:space:]' < "$etc/autoscaler.image")
    [[ "$id" =~ ^[0-9]+$ ]] || fail "NRV-E1243: there is no cloud-agent snapshot yet ($etc/autoscaler.image): run nerva-autoscaler-image.sh build, then start the service"
    printf '%s\n' "$id"
}

secrets_ok() {
    secret_file "$etc/hcloud.token" "the Hetzner API token"
    secret_file "$etc/woodpecker.token" "the Woodpecker API token"
}

count_servers() { # servers with the pool label, by the Hetzner API
    hcloud GET "/servers?label_selector=$POOL_LABEL&per_page=50" | jq -r '.servers | length'
}

check_cap() {
    local n
    n=$(count_servers)
    if [ "$n" -gt "$AS_MAX" ]; then
        echo "$tool: warning: NRV-W1208: $n servers carry the label $POOL_LABEL but the cap is $AS_MAX: delete the extra ones in the Hetzner console (a server left behind is billed by the hour)" >&2
    fi
    say "$n of at most $AS_MAX cloud servers exist"
}

help_check() { # the pinned autoscaler must know every setting `run` passes (NRV-E1240)
    local help f
    help=$(docker run --rm "$AUTOSCALER_IMAGE" --help 2>&1) || fail "NRV-E1240: could not run the autoscaler image $AUTOSCALER_IMAGE to read its flags"
    for f in max-agents agent-idle-timeout workflows-per-agent cloudinit-template hetznercloud-server-type hetznercloud-image hetznercloud-labels pool-id agent-labels agent-image server-token hetznercloud-api-token; do
        grep -q -- "$f" <<< "$help" || fail "NRV-E1240: the pinned autoscaler has no --$f: lib.sh's pin and run() disagree (decision O6)"
    done
}

# install_tree: $lib/ci/ becomes a copy of the parts of ops/ci/ that the snapshot build needs (CI_TREE):
# the build copies exactly that to the build server, where provision-image.sh finds its files beside it.
install_tree() {
    local src dst="$lib/ci" f
    src="$(cd "$here/.." && pwd)"
    for f in $CI_TREE; do
        [ -e "$src/$f" ] || fail "NRV-E1239: $src/$f is missing: install from a whole copy of ops/ci/ (scp -r ops/ci root@BOX:)"
    done
    [ "$src" != "$(cd "$lib" && pwd)/ci" ] || return 0 # already the installed copy
    rm -rf "$dst.new"
    mkdir -p "$dst.new"
    for f in $CI_TREE; do cp -r "$src/$f" "$dst.new/$f"; done
    chmod -R u=rwX,go=rX "$dst.new"
    chmod 0755 "$dst.new"/*.sh "$dst.new"/autoscaler/*.sh
    rm -rf "$dst"
    mv "$dst.new" "$dst"
}

install_all() {
    local conf="$etc/autoscaler.conf" k v f keys="AS_SERVER AS_GRPC AS_LOCATION AS_SERVER_TYPE AS_MAX AS_IDLE AS_TIER"
    [ "$(id -u)" = "${NERVA_CI_ROOT_UID:-0}" ] || fail "NRV-E1239: run as root"
    need_tools docker curl jq
    mkdir -p "$etc" "$lib" "$units"
    chmod 0755 "$etc"
    declare -A want=(
        [AS_SERVER]="${NERVA_AS_SERVER:-}" [AS_GRPC]="${NERVA_AS_GRPC:-}" [AS_LOCATION]="${NERVA_AS_LOCATION:-}"
        [AS_SERVER_TYPE]="${NERVA_AS_SERVER_TYPE:-}" [AS_MAX]="${NERVA_AS_MAX:-}" [AS_IDLE]="${NERVA_AS_IDLE:-}" [AS_TIER]=""
    )
    declare -A dflt=([AS_LOCATION]=fsn1 [AS_SERVER_TYPE]=ccx33 [AS_MAX]=4 [AS_IDLE]=10m [AS_TIER]=cloud)
    # A setting is the variable's value, else the line already in the conf, else its default. All of them
    # are checked before anything is written: the conf is sourced on every start, so it never holds a
    # value that was not checked (NRV-E1238).
    for k in $keys; do
        v="${want[$k]}"
        if [ -z "$v" ] && [ -f "$conf" ]; then v=$(sed -n "s/^$k=//p" "$conf" | tail -n 1); fi
        if [ -z "$v" ]; then v="${dflt[$k]:-}"; fi
        if [ -z "$v" ] && [ "$k" = AS_GRPC ]; then v=$(grpc_default); fi
        printf -v "$k" '%s' "$v"
    done
    conf_check
    : > "$conf.new"
    for k in $keys; do printf '%s=%s\n' "$k" "${!k}" >> "$conf.new"; done
    mv "$conf.new" "$conf"
    install_tree
    for f in nerva-autoscaler.service nerva-autoscaler-image.service nerva-autoscaler-image.timer; do
        install -m 0644 "$here/$f" "$units/$f"
    done
    secrets_ok
    help_check
    if [ "${NERVA_AS_NO_SYSTEMD:-}" != 1 ]; then
        systemctl daemon-reload
        systemctl enable --now nerva-autoscaler-image.timer
    fi
    say "OK installed (cap $AS_MAX x $AS_SERVER_TYPE in $AS_LOCATION, idle $AS_IDLE); next: nerva-autoscaler-image.sh build, then systemctl enable --now nerva-autoscaler.service"
}

run() {
    local id
    conf_load
    secrets_ok
    id=$(snapshot_id)
    exec docker run --rm --name nerva-autoscaler --read-only --cap-drop ALL --security-opt no-new-privileges \
        --memory 512m --pids-limit 256 \
        -v "$etc/hcloud.token:/run/secrets/hcloud.token:ro" \
        -v "$etc/woodpecker.token:/run/secrets/woodpecker.token:ro" \
        -v "$lib/ci/autoscaler/cloud-init.tmpl.yaml:/etc/cloud-init.tmpl.yaml:ro" \
        -e WOODPECKER_SERVER="$AS_SERVER" -e WOODPECKER_GRPC_ADDR="$AS_GRPC" -e WOODPECKER_GRPC_SECURE=true \
        -e WOODPECKER_TOKEN_FILE=/run/secrets/woodpecker.token \
        -e WOODPECKER_HETZNERCLOUD_API_TOKEN_FILE=/run/secrets/hcloud.token \
        -e WOODPECKER_PROVIDER=hetznercloud -e WOODPECKER_POOL_ID=nerva-ci \
        -e WOODPECKER_MIN_AGENTS=0 -e WOODPECKER_MAX_AGENTS="$AS_MAX" -e WOODPECKER_WORKFLOWS_PER_AGENT=1 \
        -e WOODPECKER_AGENT_IDLE_TIMEOUT="$AS_IDLE" -e WOODPECKER_AGENT_IMAGE="$AGENT_IMAGE" \
        -e WOODPECKER_AGENT_LABELS="tier=$AS_TIER,kvm=false" \
        -e WOODPECKER_CLOUDINIT_TEMPLATE_FILE=/etc/cloud-init.tmpl.yaml \
        -e WOODPECKER_HETZNERCLOUD_SERVER_TYPE="$AS_SERVER_TYPE:$AS_LOCATION" \
        -e WOODPECKER_HETZNERCLOUD_IMAGE="$id" -e WOODPECKER_HETZNERCLOUD_LABELS="$POOL_LABEL=$AS_TIER" \
        "$AUTOSCALER_IMAGE"
}

mode="${1:-}"
case "$mode" in
install) install_all ;;
check) conf_load; secrets_ok; snapshot_id > /dev/null; check_cap; say "OK" ;;
status)
    conf_load
    say "server $AS_SERVER, cap $AS_MAX x $AS_SERVER_TYPE in $AS_LOCATION, idle $AS_IDLE, snapshot $(snapshot_id)"
    secret_file "$etc/hcloud.token" "the Hetzner API token"
    hcloud GET "/servers?label_selector=$POOL_LABEL&per_page=50" | jq -r '.servers[] | "\(.id) \(.name) \(.status) \(.created)"'
    ;;
run) run ;;
*) echo "usage: nerva-autoscaler.sh install|check|status|run" >&2; exit 2 ;;
esac
