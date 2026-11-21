#!/usr/bin/env bash
# Runs on the CI box, as root (decision O6): builds the Hetzner snapshot that cloud agents boot from, and
# deletes old ones. Installed by nerva-autoscaler.sh install; a systemd timer runs `build` and `prune`
# nightly, then restarts the autoscaler so that new servers use the new snapshot.
#
#   build   Creates a temporary server (the configured type and location, Ubuntu 24.04) with a throwaway
#           SSH key, copies ops/ci/'s docker/, io_uring_probe.sh, nerva-woodpecker.sh and autoscaler/ and a copy of the box's main cache (the read-only warm-cache seed) to
#           it, runs provision-image.sh there, powers it off, snapshots it (label nerva-ci-pool=snapshot)
#           and writes the snapshot's id to /etc/nerva-ci/autoscaler.image. The server and the key are
#           deleted on any exit. A failure is NRV-E1242 and leaves the previous snapshot in use.
#   prune   Deletes all but the newest KEEP (2) snapshots with the label, never the one in use.
#   latest  Prints the newest snapshot's id.
#
# The Hetzner token is read from /etc/nerva-ci/hcloud.token (root, 0600) and passed to curl on stdin
# (lib.sh `hcloud`): never in argv, the environment or a log. Needs curl, jq, ssh, ssh-keygen and rsync.
# Where it looks, for ci/autoscaler_test.sh: NERVA_CI_ETC, NERVA_HCLOUD_API, NERVA_CI_CACHE_ROOT
# (/var/cache/nerva-ci), NERVA_AS_KEEP (2: how many snapshots prune keeps, at least 1) and NERVA_AS_POLL
# (10: seconds between polls).
# shellcheck disable=SC2154,SC2034 # etc, tool and the pins come from lib.sh (not followed: no -x)
set -euo pipefail

tool=nerva-autoscaler-image
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

keep="${NERVA_AS_KEEP:-2}"
[[ "$keep" =~ ^[0-9]+$ ]] && [ "$keep" -ge 1 ] && [ "$keep" -le 10 ] || fail "NRV-E1238: NERVA_AS_KEEP='$keep' is not a number from 1 to 10"

snapshots() { # newest first: "id created"
    hcloud GET "/images?type=snapshot&label_selector=$POOL_LABEL%3Dsnapshot&sort=created:desc&per_page=50" | jq -r '.images[] | "\(.id) \(.created)"'
}

latest() {
    local id
    id=$(snapshots | head -n 1 | cut -d ' ' -f 1)
    [ -n "$id" ] || fail "NRV-E1243: there is no cloud-agent snapshot: run nerva-autoscaler-image.sh build"
    printf '%s\n' "$id"
}

prune() {
    local id used="" n=0
    [ ! -f "$etc/autoscaler.image" ] || used=$(tr -d '[:space:]' < "$etc/autoscaler.image")
    while read -r id _; do
        n=$((n + 1))
        if [ "$n" -gt "$keep" ] && [ "$id" != "$used" ]; then
            hcloud DELETE "/images/$id" > /dev/null
            say "deleted old snapshot $id"
        fi
    done < <(snapshots)
    say "kept the newest $keep snapshots"
}

wait_for() { # wait_for DESCRIPTION JQ_EXPR PATH: polls (at most 60 x 10 s) until the jq expression holds
    local i
    for i in $(seq 1 60); do
        if hcloud GET "$3" | jq -e "$2" > /dev/null; then return 0; fi
        sleep "${NERVA_AS_POLL:-10}"
    done
    fail "NRV-E1242: the image was not built: gave up waiting for $1 (10 minutes)"
}

build() {
    local tmp key_id="" srv_id="" ip stamp seed img i tree
    local -a ssh_opts
    [ "$(id -u)" = "${NERVA_CI_ROOT_UID:-0}" ] || fail "NRV-E1242: the image was not built: run as root"
    conf_load
    secret_file "$etc/hcloud.token" "the Hetzner API token"
    seed="${NERVA_CI_CACHE_ROOT:-/var/cache/nerva-ci}/main"
    [ -d "$seed" ] && [ -n "$(ls -A "$seed")" ] || fail "NRV-E1242: the image was not built: the box's main cache $seed is missing or empty (run a pipeline on main first: it is the warm-cache seed)"
    for i in curl jq ssh ssh-keygen rsync; do command -v "$i" > /dev/null || fail "NRV-E1239: $i is not installed"; done
    tmp=$(mktemp -d /var/tmp/nerva-image.XXXXXX)
    # shellcheck disable=SC2064
    trap "cleanup_build '$tmp'" EXIT
    stamp=$(date -u +%Y%m%d-%H%M)
    ssh-keygen -q -t ed25519 -N '' -f "$tmp/key" -C "nerva-ci-image-$stamp"
    key_id=$(hcloud POST /ssh_keys "$(jq -n --arg n "nerva-ci-image-$stamp-$$" --arg k "$(cat "$tmp/key.pub")" --arg l "$POOL_LABEL" '{name: $n, public_key: $k, labels: {($l): "image-build"}}')" | jq -r '.ssh_key.id')
    echo "$key_id" > "$tmp/key_id"
    srv_id=$(hcloud POST /servers "$(jq -n --arg n "nerva-ci-image-$stamp" --arg t "$AS_SERVER_TYPE" --arg l "$AS_LOCATION" --argjson k "$key_id" --arg p "$POOL_LABEL" \
        '{name: $n, server_type: $t, location: $l, image: "ubuntu-24.04", ssh_keys: [$k], start_after_create: true, labels: {($p): "image-build"}}')" | jq -r '.server.id')
    echo "$srv_id" > "$tmp/srv_id"
    say "build server $srv_id created"
    wait_for "the build server to run" '.server.status == "running"' "/servers/$srv_id"
    ip=$(hcloud GET "/servers/$srv_id" | jq -r '.server.public_net.ipv4.ip')
    ssh_opts=(-i "$tmp/key" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$tmp/known_hosts" -o ConnectTimeout=10)
    for i in $(seq 1 60); do
        if ssh "${ssh_opts[@]}" "root@$ip" true 2> /dev/null; then break; fi
        [ "$i" -lt 60 ] || fail "NRV-E1242: the image was not built: the build server did not accept SSH in 10 minutes"
        sleep "${NERVA_AS_POLL:-10}"
    done
    tree="$(cd "$here/.." && pwd)"
    # shellcheck disable=SC2046 # CI_TREE is a list of names without spaces
    rsync -a -e "ssh ${ssh_opts[*]}" $(for i in $CI_TREE; do printf '%s ' "$tree/$i"; done) "root@$ip:/root/ci/" || fail "NRV-E1242: the image was not built: could not copy ops/ci to the build server"
    ssh "${ssh_opts[@]}" "root@$ip" 'install -d -m 0755 /var/cache/nerva-ci/main'
    rsync -a -e "ssh ${ssh_opts[*]}" "$seed/" "root@$ip:/var/cache/nerva-ci/main/" || fail "NRV-E1242: the image was not built: could not copy the warm-cache seed to the build server"
    ssh "${ssh_opts[@]}" "root@$ip" 'NERVA_AS_ON_BUILD_SERVER=yes bash /root/ci/autoscaler/provision-image.sh' || fail "NRV-E1242: the image was not built: provisioning failed on the build server (output above)"
    hcloud POST "/servers/$srv_id/actions/poweroff" > /dev/null
    wait_for "the build server to power off" '.server.status == "off"' "/servers/$srv_id"
    img=$(hcloud POST "/servers/$srv_id/actions/create_image" "$(jq -n --arg d "nerva-ci-agent-$stamp" --arg l "$POOL_LABEL" '{type: "snapshot", description: $d, labels: {($l): "snapshot"}}')" | jq -r '.image.id')
    [[ "$img" =~ ^[0-9]+$ ]] || fail "NRV-E1242: the image was not built: Hetzner returned no snapshot id"
    wait_for "the snapshot $img to be available" '.image.status == "available"' "/images/$img"
    printf '%s\n' "$img" > "$etc/autoscaler.image.new"
    chmod 0644 "$etc/autoscaler.image.new"
    mv "$etc/autoscaler.image.new" "$etc/autoscaler.image"
    say "OK snapshot $img (nerva-ci-agent-$stamp) is now the one cloud agents boot from"
}

# cleanup_build TMP: deletes the build server and the SSH key, whatever happened (an exit trap).
cleanup_build() {
    local rc=$? id
    set +e
    if [ -s "$1/srv_id" ]; then id=$(cat "$1/srv_id"); hcloud DELETE "/servers/$id" > /dev/null 2>&1 || echo "$tool: warning: could not delete the build server $id: delete it in the Hetzner console" >&2; fi
    if [ -s "$1/key_id" ]; then id=$(cat "$1/key_id"); hcloud DELETE "/ssh_keys/$id" > /dev/null 2>&1 || echo "$tool: warning: could not delete the build SSH key $id" >&2; fi
    rm -rf "$1"
    exit "$rc"
}

case "${1:-}" in
build) build ;;
prune) conf_load; secret_file "$etc/hcloud.token" "the Hetzner API token"; prune ;;
latest) secret_file "$etc/hcloud.token" "the Hetzner API token"; latest ;;
*) echo "usage: nerva-autoscaler-image.sh build|prune|latest" >&2; exit 2 ;;
esac
