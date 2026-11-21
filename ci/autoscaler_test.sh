#!/usr/bin/env bash
# Tests of the cloud-agent setup (decision O6): ops/ci/autoscaler/*, the tier labels of .woodpecker/ and the
# check-packages shards of ci/job.sh. Run by ci/job.sh check-scripts, from the repository root. No Docker,
# no network and no Hetzner: `docker`, `curl` and `ssh` are stubs on PATH. Codes it triggers (docs/ERRORS.md):
# NRV-E1237 (secret files), E1238 (settings), E1239 (tools), E1240 (autoscaler flags), E1241 (Hetzner API),
# E1242 (snapshot build), E1243 (no snapshot), E1244 (shard table), NRV-W1208 (servers over the cap).
# What it cannot test: a real Hetzner project, the autoscaler itself, a real snapshot build.
set -uo pipefail

root="$(pwd)"
as="$root/ops/ci/autoscaler"
tmp=$(mktemp -d "${CI_TEST_TMP:-/var/tmp}/autoscaler-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
n=0
bad() { echo "FAIL autoscaler_test: $*" >&2; fail=1; }

# refuses DESC CODE CMD...: the command fails, and its output has CODE.
refuses() {
    local desc=$1 code=$2 out
    shift 2
    n=$((n + 1))
    if out=$("$@" 2>&1); then bad "$desc: succeeded, wanted $code: $out"; return; fi
    grep -q "$code" <<< "$out" || bad "$desc: no $code in: $out"
}
ok() { # ok DESC CMD...
    local desc=$1 out
    shift
    n=$((n + 1))
    out=$("$@" 2>&1) || bad "$desc: failed: $out"
}
has() { # has DESC FILE PATTERN
    n=$((n + 1))
    grep -qE -- "$3" "$2" || bad "$1: no match for $3 in $2"
}
hasnt() { # hasnt DESC FILE PATTERN
    n=$((n + 1))
    if grep -qE -- "$3" "$2"; then bad "$1: found $3 in $2"; fi
}

# --- Stubs --------------------------------------------------------------------------------------
stubs="$tmp/stubs"
mkdir -p "$stubs"
cat > "$stubs/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG/docker.args"
if [ "${2:-}" = --help ] || [[ " $* " == *" --help "* ]]; then cat "$STUB_HELP"; exit 0; fi
exit 0
EOF
# curl: records stdin (where the token must be) and argv, answers from $STUB_API/<METHOD>_<path with / as _>.
cat > "$stubs/curl" <<'EOF'
#!/usr/bin/env bash
cat > "$STUB_LOG/curl.stdin"
printf '%s\n' "$*" >> "$STUB_LOG/curl.args"
method=GET; url=""
while [ $# -gt 0 ]; do
    case "$1" in -X) method=$2; shift ;; http*) url=$1 ;; esac
    shift
done
p=${url#*/v1}; p=${p%%\?*}
f="$STUB_API/${method}_$(echo "$p" | tr / _)"
echo "$method $p" >> "$STUB_LOG/curl.calls"
# $f.N answers the Nth call of that path, if there is one (a server that is running, then off).
c=$(( $(cat "$STUB_LOG/cnt_$(basename "$f")" 2>/dev/null || echo 0) + 1 ))
echo "$c" > "$STUB_LOG/cnt_$(basename "$f")"
if [ -f "$f.$c" ]; then cat "$f.$c"; elif [ -f "$f" ]; then cat "$f"; else printf '{}\n200'; fi
EOF
# ssh-keygen makes the key pair named by -f; ssh fails the provisioning when STUB_SSH_FAIL is set; rsync and ssh log.
cat > "$stubs/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do case "$1" in -f) k=$2; shift ;; esac; shift; done
echo private > "$k"
echo "ssh-ed25519 AAAA stub" > "$k.pub"
EOF
cat > "$stubs/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG/ssh.args"
if [ -n "${STUB_SSH_FAIL:-}" ] && [[ "$*" == *provision-image* ]]; then exit 1; fi
exit 0
EOF
cat > "$stubs/rsync" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG/rsync.args"
st=free
if [ -n "${STUB_LOCK:-}" ] && [ -f "$STUB_LOCK" ] && ! flock -x -n "$STUB_LOCK" true; then st=held; fi
printf '%s %s\n' "$st" "$*" >> "$STUB_LOG/rsync.lock"
exit 0
EOF
chmod +x "$stubs"/*
export STUB_LOG="$tmp/log" STUB_API="$tmp/api" STUB_HELP="$tmp/help.txt"
mkdir -p "$STUB_LOG" "$STUB_API"
# The help text lists the environment variables the script passes, as urfave/cli prints them: [$NAME].
env_names=$(grep -o '"WOODPECKER_[A-Z_]*=' "$root/ops/ci/autoscaler/nerva-autoscaler.sh" | tr -d '"=' | sort -u)
for f in $env_names; do echo "--flag value (env) [\$$f]" >> "$STUB_HELP"; done

uid=$(id -u)
export NERVA_CI_ROOT_UID=$uid NERVA_AS_NO_SYSTEMD=1 NERVA_AS_POLL=0 PATH="$stubs:$PATH" NERVA_AS_LOCK="$tmp/image.lock"
etc="$tmp/etc"
export NERVA_CI_ETC="$etc" NERVA_AS_LIB="$tmp/lib" NERVA_AS_UNITS="$tmp/units" NERVA_HCLOUD_API=https://hcloud.test/v1
mkdir -p "$etc"
chmod 0755 "$tmp" "$etc"
secret() { printf '%s\n' "$2" > "$etc/$1"; chmod 0600 "$etc/$1"; }
token='hcloud-SECRET-1234'

# --- Secret files (NRV-E1237) -------------------------------------------------------------------
tool=autoscaler_test
# shellcheck source=/dev/null
(
    . "$as/lib.sh"
    exit 0
) || bad "lib.sh does not source"
sf() { ( tool="test"; export tool; . "$as/lib.sh"; secret_file "$@" ); }
refuses "missing token file" NRV-E1237 sf "$etc/hcloud.token" "the Hetzner API token"
printf 'x\n' > "$etc/hcloud.token"
chmod 0644 "$etc/hcloud.token"
refuses "world-readable token file" NRV-E1237 sf "$etc/hcloud.token" "the Hetzner API token"
chmod 0600 "$etc/hcloud.token"
: > "$etc/hcloud.token"
refuses "empty token file" NRV-E1237 sf "$etc/hcloud.token" "the Hetzner API token"
ln -sf "$etc/hcloud.token" "$etc/link.token"
refuses "symlinked token file" NRV-E1237 sf "$etc/link.token" "a token"
rm -f "$etc/link.token"
secret hcloud.token "$token"
ok "a root-only token file" sf "$etc/hcloud.token" "the Hetzner API token"
secret woodpecker.token "wp-SECRET-5678"

# --- install: settings (NRV-E1238), tools, flags (NRV-E1240) -------------------------------------
inst() { bash "$as/nerva-autoscaler.sh" install; }
refuses "install without a server" NRV-E1238 inst
export NERVA_AS_SERVER=https://ci.example.org
export NERVA_WP_ENV="$tmp/ci.env"
refuses "install without CI_GRPC_HOST (no ci.env)" NRV-E1238 inst
echo 'CI_GRPC_HOST=' > "$tmp/ci.env"
refuses "install with an empty CI_GRPC_HOST" NRV-E1238 inst
echo 'CI_GRPC_HOST=grpc.example.org' > "$tmp/ci.env"
for g in grpc.example.org:9000 grpc.example.org:09000 grpc.example.org:8000 grpc.example.org:80 grpc.example.org:4430 grpc.example.org:1443; do
    refuses "the gRPC address $g is not :443" NRV-E1238 env NERVA_AS_GRPC=$g bash "$as/nerva-autoscaler.sh" install
done
# A bad value is refused before it is written, so it is never sourced (here: it would touch a file).
refuses "a server that runs a command" NRV-E1238 env 'NERVA_AS_SERVER=https://x$(touch '"$tmp"'/pwned)' bash "$as/nerva-autoscaler.sh" install
n=$((n + 1))
{ [ ! -e "$tmp/pwned" ] && [ ! -e "$etc/autoscaler.conf" ]; } || bad "a refused setting was written to the conf or run"
refuses "a shared-vCPU server type" NRV-E1238 env NERVA_AS_SERVER_TYPE=cx32 bash "$as/nerva-autoscaler.sh" install
refuses "a cap of 0" NRV-E1238 env NERVA_AS_MAX=0 bash "$as/nerva-autoscaler.sh" install
refuses "a cap over the maximum" NRV-E1238 env NERVA_AS_MAX=17 bash "$as/nerva-autoscaler.sh" install
refuses "an idle time in hours" NRV-E1238 env NERVA_AS_IDLE=2h bash "$as/nerva-autoscaler.sh" install
refuses "a plain http server" NRV-E1238 env NERVA_AS_SERVER=http://ci.example.org bash "$as/nerva-autoscaler.sh" install
rm -f "$etc/autoscaler.conf"
# A help text that lacks one variable the script passes is refused, for each of them (a flag name is no proof).
n=$((n + 1))
[ "$(wc -l < "$STUB_HELP")" -ge 15 ] || bad "the help stub lists too few variables"
for f in $env_names; do
    grep -vF "[\$$f]" "$STUB_HELP" > "$tmp/nohelp.txt"
    refuses "an autoscaler without \$$f" NRV-E1240 env STUB_HELP="$tmp/nohelp.txt" bash "$as/nerva-autoscaler.sh" install
    rm -f "$etc/autoscaler.conf"
done
printf '%s\n' '--max-agents value' '--agent-labels value' > "$tmp/nohelp.txt"
refuses "flag names without their environment variables" NRV-E1240 env STUB_HELP="$tmp/nohelp.txt" bash "$as/nerva-autoscaler.sh" install
rm -f "$etc/autoscaler.conf"
ok "install" inst
has "conf has the server" "$etc/autoscaler.conf" '^AS_SERVER=https://ci.example.org$'
has "conf takes the gRPC address from the bootstrap's CI_GRPC_HOST, on 443" "$etc/autoscaler.conf" '^AS_GRPC=grpc.example.org:443$'
has "conf has the default cap" "$etc/autoscaler.conf" '^AS_MAX=4$'
has "conf has the dedicated type" "$etc/autoscaler.conf" '^AS_SERVER_TYPE=ccx33$'
hasnt "conf holds no secret" "$etc/autoscaler.conf" "SECRET"
for f in autoscaler/nerva-autoscaler.sh autoscaler/nerva-autoscaler-image.sh autoscaler/provision-image.sh autoscaler/lib.sh autoscaler/cloud-init.tmpl.yaml \
    docker/seccomp-io_uring.json io_uring_probe.sh nerva-woodpecker.sh; do
    n=$((n + 1))
    [ -f "$tmp/lib/ci/$f" ] || bad "install did not copy ci/$f"
done
n=$((n + 1))
[ -x "$tmp/lib/ci/autoscaler/nerva-autoscaler.sh" ] || bad "the installed nerva-autoscaler.sh is not executable"
for f in nerva-autoscaler.service nerva-autoscaler-image.service nerva-autoscaler-image.timer nerva-autoscaler-check.service nerva-autoscaler-check.timer; do
    n=$((n + 1))
    [ -f "$tmp/units/$f" ] || bad "install did not write $f"
done
# With systemd (a stub that logs), install enables both timers and try-restarts the autoscaler as its last step.
cat > "$stubs/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG/systemctl.args"
EOF
chmod +x "$stubs/systemctl"
: > "$STUB_LOG/systemctl.args"
ok "install with systemd" env NERVA_AS_NO_SYSTEMD=0 bash "$as/nerva-autoscaler.sh" install
has "install enables both timers" "$STUB_LOG/systemctl.args" '^enable --now nerva-autoscaler-image.timer nerva-autoscaler-check.timer$'
n=$((n + 1))
[ "$(tail -n 1 "$STUB_LOG/systemctl.args")" = "try-restart nerva-autoscaler.service" ] || bad "install does not end with a try-restart of the autoscaler: $(cat "$STUB_LOG/systemctl.args")"
hasnt "install never starts a stopped autoscaler" "$STUB_LOG/systemctl.args" '^(restart|start) '
ok "install again keeps and changes settings" env NERVA_AS_MAX=2 bash "$as/nerva-autoscaler.sh" install
has "the cap changed" "$etc/autoscaler.conf" '^AS_MAX=2$'
has "the server was kept" "$etc/autoscaler.conf" '^AS_SERVER=https://ci.example.org$'
refuses "install without the Woodpecker token" NRV-E1237 env NERVA_CI_ETC="$tmp/etc2" bash "$as/nerva-autoscaler.sh" install

# --- run: no snapshot (NRV-E1243), then the container's arguments --------------------------------
run() { bash "$as/nerva-autoscaler.sh" run; }
refuses "run without a snapshot" NRV-E1243 run
echo 4242 > "$etc/autoscaler.image"
: > "$STUB_LOG/docker.args"
ok "run" run
a="$STUB_LOG/docker.args"
has "run is read-only" "$a" '--read-only'
has "run drops every capability" "$a" '--cap-drop ALL'
has "run has no new privileges" "$a" 'no-new-privileges'
hasnt "run is not privileged" "$a" '--privileged'
hasnt "run has no Docker socket" "$a" 'docker.sock'
has "run reaches the server through Caddy, with TLS" "$a" 'WOODPECKER_GRPC_ADDR=grpc.example.org:443'
has "run uses TLS" "$a" 'WOODPECKER_GRPC_SECURE=true'
has "run caps the servers" "$a" 'WOODPECKER_MAX_AGENTS=2'
has "run names the snapshot" "$a" 'WOODPECKER_HETZNERCLOUD_IMAGE=4242'
has "run uses a dedicated type in the box's location" "$a" 'WOODPECKER_HETZNERCLOUD_SERVER_TYPE=ccx33:fsn1'
has "run counts only the cloud workflows" "$a" 'WOODPECKER_FILTER_LABELS=tier=cloud'
has "run labels the agents" "$a" 'WOODPECKER_AGENT_LABELS=tier=cloud,kvm=false'
has "run has one workflow per agent" "$a" 'WOODPECKER_WORKFLOWS_PER_AGENT=1'
has "run passes the token files read-only" "$a" 'hcloud.token:/run/secrets/hcloud.token:ro'
has "run pins the image by digest" "$a" 'autoscaler:2.1.0@sha256:[0-9a-f]{64}'
hasnt "no secret in the arguments" "$a" 'SECRET'

# --- check and status: the cap (NRV-W1208) -------------------------------------------------------
servers() { printf '{"servers":[%s]}\n200' "$1" > "$STUB_API/GET__servers"; }
servers '{"id":1}'
ok "check with a server below the cap" bash "$as/nerva-autoscaler.sh" check
servers '{"id":1},{"id":2},{"id":3}'
out=$(bash "$as/nerva-autoscaler.sh" check 2>&1)
n=$((n + 1))
grep -q NRV-W1208 <<< "$out" || bad "no NRV-W1208 with 3 servers over a cap of 2: $out"
# A cloud server over 12 hours old was leaked, whatever the count.
servers '{"id":1,"created":"2020-01-01T00:00:00+00:00"}'
out=$(bash "$as/nerva-autoscaler.sh" check 2>&1)
n=$((n + 1))
grep -q 'NRV-W1208.*over 12 hours' <<< "$out" || bad "no NRV-W1208 for a server over 12 hours old: $out"
servers '{"id":1,"created":"2099-01-01T00:00:00+00:00"}'
n=$((n + 1))
if bash "$as/nerva-autoscaler.sh" check 2>&1 | grep -q 'over 12 hours'; then bad "a young server was called leaked"; fi
servers '{"id":1},{"id":2},{"id":3}'
has "the token went to curl on stdin" "$STUB_LOG/curl.stdin" "Bearer $token"
hasnt "the token is not in curl's argv" "$STUB_LOG/curl.args" "SECRET"
printf '{"error":{"message":"no"}}\n403' > "$STUB_API/GET__servers"
refuses "a refused Hetzner call" NRV-E1241 bash "$as/nerva-autoscaler.sh" check

# --- the snapshot script: prune keeps 2 and the one in use; latest; build refuses (NRV-E1242) ----
img="$as/nerva-autoscaler-image.sh"
printf '{"images":[{"id":40,"created":"d"},{"id":30,"created":"c"},{"id":20,"created":"b"},{"id":10,"created":"a"}]}\n200' > "$STUB_API/GET__images"
: > "$STUB_LOG/curl.calls"
echo 10 > "$etc/autoscaler.image"
ok "prune" bash "$img" prune
has "prune deleted 20" "$STUB_LOG/curl.calls" '^DELETE /images/20$'
hasnt "prune kept the newest" "$STUB_LOG/curl.calls" '^DELETE /images/(40|30)$'
hasnt "prune kept the one in use" "$STUB_LOG/curl.calls" '^DELETE /images/10$'
n=$((n + 1))
[ "$(bash "$img" latest)" = 40 ] || bad "latest is not the newest"
printf '{"images":[]}\n200' > "$STUB_API/GET__images"
refuses "latest with no snapshot" NRV-E1243 bash "$img" latest
refuses "build without a seed" NRV-E1242 env NERVA_CI_CACHE_ROOT="$tmp/noseed" bash "$img" build
refuses "provision off the build server" NRV-E1242 bash "$as/provision-image.sh"
# With a keep count of 1 the newest and the one in use (10, here an older one) are still kept.
: > "$STUB_LOG/curl.calls"
printf '{"images":[{"id":40,"created":"d"},{"id":30,"created":"c"},{"id":20,"created":"b"},{"id":10,"created":"a"}]}\n200' > "$STUB_API/GET__images"
ok "prune with a keep count of 1" env NERVA_AS_KEEP=1 bash "$img" prune
has "keep 1 deleted 30 and 20" "$STUB_LOG/curl.calls" '^DELETE /images/30$'
hasnt "keep 1 kept the newest" "$STUB_LOG/curl.calls" '^DELETE /images/40$'
hasnt "keep 1 kept the one in use" "$STUB_LOG/curl.calls" '^DELETE /images/10$'
printf '{"images":[]}\n200' > "$STUB_API/GET__images"
refuses "a keep count of 0" NRV-E1238 env NERVA_AS_KEEP=0 bash "$img" prune
rm -f "$etc/hcloud.token"
refuses "build without the token file" NRV-E1237 env NERVA_CI_CACHE_ROOT="$tmp/noseed" bash "$img" build

# --- build, from the INSTALLED copy, against stubs: what it copies is what provision-image.sh needs ----
secret hcloud.token "$token"
mkdir -p "$tmp/cache/main/tools" "$tmp/cache/main/zig/p/h" "$tmp/cache/main/zig-local" "$tmp/cache/locks"
echo seed > "$tmp/cache/main/tools/x"
echo pkg > "$tmp/cache/main/zig/p/h/y"
echo local > "$tmp/cache/main/zig-local/z"
: > "$tmp/cache/locks/main.lock"
export STUB_LOCK="$tmp/cache/locks/main.lock"
inst_img="$tmp/lib/ci/autoscaler/nerva-autoscaler-image.sh"
api_for_build() {
    rm -f "$STUB_API"/* "$STUB_LOG"/cnt_* "$STUB_LOG/rsync.args" "$STUB_LOG/ssh.args" "$STUB_LOG/rsync.lock"
    : > "$STUB_LOG/curl.calls"
    printf '{"servers":[]}\n200' > "$STUB_API/GET__servers"
    printf '{"ssh_keys":[]}\n200' > "$STUB_API/GET__ssh_keys"
    printf '{"ssh_key":{"id":7}}\n201' > "$STUB_API/POST__ssh_keys"
    printf '{"server":{"id":8}}\n201' > "$STUB_API/POST__servers"
    printf '{"server":{"status":"running","public_net":{"ipv4":{"ip":"1.2.3.4"}}}}\n200' > "$STUB_API/GET__servers_8.1"
    cp "$STUB_API/GET__servers_8.1" "$STUB_API/GET__servers_8.2"
    printf '{"server":{"status":"off","public_net":{"ipv4":{"ip":"1.2.3.4"}}}}\n200' > "$STUB_API/GET__servers_8"
    printf '{"image":{"id":55}}\n201' > "$STUB_API/POST__servers_8_actions_create_image"
    printf '{"image":{"status":"available"}}\n200' > "$STUB_API/GET__images_55"
}
build_inst() { NERVA_CI_CACHE_ROOT="$tmp/cache" bash "$inst_img" build; }
api_for_build
rm -f "$etc/autoscaler.image"
ok "build from the installed copy" build_inst
n=$((n + 1))
[ "$(cat "$etc/autoscaler.image")" = 55 ] || bad "build did not write the snapshot id"
has "build ran provision-image.sh where rsync put it" "$STUB_LOG/ssh.args" 'bash /root/ci/autoscaler/provision-image.sh'
has "build deleted its server" "$STUB_LOG/curl.calls" '^DELETE /servers/8$'
has "build deleted its key" "$STUB_LOG/curl.calls" '^DELETE /ssh_keys/7$'
# The seed is tools/ and zig/p/ of main's cache only, copied while holding main's lock shared.
has "the seed copy has tools" "$STUB_LOG/rsync.lock" '^held .*-aR .* tools zig/p root@1.2.3.4:/var/cache/nerva-ci/main/$'
hasnt "the seed copy leaves zig-local out" "$STUB_LOG/rsync.lock" 'zig-local'
# What rsync copied to /root/ci/ is, with nothing else, what provision-image.sh opens (relative to its own place).
rm -rf "$tmp/remote"
mkdir -p "$tmp/remote/ci"
n=$((n + 1))
sources=$(grep -- 'root@1.2.3.4:/root/ci/$' "$STUB_LOG/rsync.args" | head -n 1)
[ -n "$sources" ] || bad "build did not rsync the tree to /root/ci/"
for src in $sources; do
    case "$src" in "$tmp"/lib/ci/*) cp -r "$src" "$tmp/remote/ci/" ;; esac
done
n=$((n + 1))
{ [ ! -e "$tmp/remote/ci/lib" ] && [ -f "$tmp/remote/ci/autoscaler/provision-image.sh" ]; } || bad "build did not copy autoscaler/provision-image.sh to /root/ci/autoscaler/"
refs=$(grep -o '\$here/[^" ]*' "$as/provision-image.sh" | sort -u)
n=$((n + 1))
[ -n "$refs" ] || bad "no here paths found in provision-image.sh"
for r in $refs; do
    n=$((n + 1))
    [ -e "$tmp/remote/ci/autoscaler/${r#\$here/}" ] || bad "provision-image.sh opens $r, which the build does not copy to the build server"
done

# --- The exit trap and the sweep (the stubs fail the build after its server exists) --------------------
now=$(date -u +%Y-%m-%dT%H:%M:%S+00:00)
api_for_build
printf '{"servers":[{"id":91,"created":"2020-01-01T00:00:00+00:00"},{"id":92,"created":"%s"}]}\n200' "$now" > "$STUB_API/GET__servers"
printf '{"ssh_keys":[{"id":93,"created":"2020-01-01T00:00:00Z"},{"id":94,"created":"%s"}]}\n200' "$now" > "$STUB_API/GET__ssh_keys"
STUB_SSH_FAIL=1 refuses "a build whose provisioning fails" NRV-E1242 build_inst
has "the trap deleted the server" "$STUB_LOG/curl.calls" '^DELETE /servers/8$'
has "the trap deleted the key" "$STUB_LOG/curl.calls" '^DELETE /ssh_keys/7$'
has "the sweep deleted a leftover server" "$STUB_LOG/curl.calls" '^DELETE /servers/91$'
has "the sweep deleted a leftover key" "$STUB_LOG/curl.calls" '^DELETE /ssh_keys/93$'
hasnt "the sweep kept the young server" "$STUB_LOG/curl.calls" '^DELETE /servers/92$'
hasnt "the sweep kept the young key" "$STUB_LOG/curl.calls" '^DELETE /ssh_keys/94$'
# The create call's reply is lost: the server exists, but its id was never read. The trap finds it by name.
api_for_build
printf '{"error":{"message":"timeout"}}\n500' > "$STUB_API/POST__servers"
printf '{"servers":[{"id":9,"created":"%s"}]}\n200' "$now" > "$STUB_API/GET__servers"
refuses "a build whose create reply is lost" NRV-E1241 build_inst
has "the trap found the server by its name" "$STUB_LOG/curl.calls" '^GET /servers$'
has "the trap deleted that server" "$STUB_LOG/curl.calls" '^DELETE /servers/9$'
has "the trap deleted the key of that build" "$STUB_LOG/curl.calls" '^DELETE /ssh_keys/7$'
# The server is locked while it is snapshotted: the first delete is refused, the trap retries.
api_for_build
printf '{"error":{"message":"locked"}}\n423' > "$STUB_API/DELETE__servers_8.1"
STUB_SSH_FAIL=1 refuses "a build whose server is locked at the first delete" NRV-E1242 build_inst
n=$((n + 1))
[ "$(grep -c '^DELETE /servers/8$' "$STUB_LOG/curl.calls")" = 2 ] || bad "the trap did not retry the refused delete of the server"
# Two builds at once: the second is refused and touches nothing. Names carry the second and the pid.
api_for_build
flock -x "$NERVA_AS_LOCK" sleep 2 &
lockpid=$!
sleep 0.5
refuses "a second build while one runs" NRV-E1242 build_inst
wait "$lockpid"
n=$((n + 1))
[ ! -s "$STUB_LOG/curl.calls" ] || bad "a refused second build called the Hetzner API: $(cat "$STUB_LOG/curl.calls")"
api_for_build
ok "a build after the lock is free" build_inst
has "the server name has the second and the pid" "$STUB_LOG/curl.args" 'nerva-ci-image-[0-9]{8}-[0-9]{6}-[0-9]+'
api_for_build

# --- NRV-E1239: not root, a tool missing --------------------------------------------------------------
bash_bin=$(command -v bash)
lim() { # lim OMIT: a directory of the stubs and the tools the scripts use, without OMIT, for a PATH of its own
    local d="$tmp/lim-$1" t
    mkdir -p "$d"
    for t in dirname id stat ls cat tr grep sed mkdir chmod install mv cp rm head cut date mktemp seq sleep basename readlink jq curl docker ssh ssh-keygen rsync; do
        [ "$t" = "$1" ] || ln -sf "$(command -v "$t")" "$d/$t"
    done
    echo "$d"
}
refuses "install as another user" NRV-E1239 env NERVA_CI_ROOT_UID=99999 bash "$as/nerva-autoscaler.sh" install
for t in jq docker curl; do
    refuses "install without $t" NRV-E1239 env PATH="$(lim "$t")" "$bash_bin" "$as/nerva-autoscaler.sh" install
done
for t in ssh rsync ssh-keygen; do
    refuses "build without $t" NRV-E1239 env PATH="$(lim "$t")" NERVA_CI_CACHE_ROOT="$tmp/cache" "$bash_bin" "$inst_img" build
done

# --- Pins agree with the rest of the repository ---------------------------------------------------
pin() { sed -n "s/^$1=//p" "$as/lib.sh"; }
n=$((n + 1))
[ "$(pin ZIG_VERSION)" = "$(sed -n 's/^ZIG_RELEASE="\(.*\)"/\1/p' zig/download.sh)" ] || bad "lib.sh ZIG_VERSION is not zig/download.sh's"
has "the Zig sha256 is zig/download.sh's" zig/download.sh "zig-x86_64-linux-$(pin ZIG_VERSION).tar.xz $(pin ZIG_SHA256)"
has "the CI image is the probe's" ops/ci/io_uring_probe.sh "^image=$(pin CI_IMAGE)\$"
n=$((n + 1))
ci_image=$(pin CI_IMAGE)
for f in .woodpecker/*.yaml; do
    grep -h '^ *image:' "$f" | grep -q . || continue
    if grep -h '^ *image:' "$f" | grep -qv "$ci_image"; then bad "$f uses an image other than the pinned CI image"; fi
done
agent_tag=$(pin AGENT_IMAGE | sed -n 's/.*:\(v[0-9.]*\)@.*/\1/p')
has "the agent image is the bootstrap's Woodpecker version" ops/ci/woodpecker-bootstrap.sh "^woodpecker_version=$agent_tag\$"
has "the unit runs the installed script" "$as/nerva-autoscaler.service" 'ExecStart=/usr/local/lib/nerva-ci/ci/autoscaler/nerva-autoscaler.sh run'
has "the image unit runs the installed script" "$as/nerva-autoscaler-image.service" 'ExecStart=/usr/local/lib/nerva-ci/ci/autoscaler/nerva-autoscaler-image.sh build'

# --- The units and the template: no orphaned container, no restart of a stopped service, no metadata ----
u="$as/nerva-autoscaler.service"
has "the service removes a leftover container before it starts" "$u" '^ExecStartPre=-/usr/bin/docker rm -f nerva-autoscaler$'
has "the service removes the container when it stops" "$u" '^ExecStop=-/usr/bin/docker rm -f nerva-autoscaler$'
has "the service removes the container however it ended" "$u" '^ExecStopPost=-/usr/bin/docker rm -f nerva-autoscaler$'
has "the image service runs the W1208 check after the restart" "$as/nerva-autoscaler-image.service" '^ExecStartPost=-/usr/local/lib/nerva-ci/ci/autoscaler/nerva-autoscaler.sh check$'
has "the check service runs check" "$as/nerva-autoscaler-check.service" '^ExecStart=/usr/local/lib/nerva-ci/ci/autoscaler/nerva-autoscaler.sh check$'
has "the check timer is hourly" "$as/nerva-autoscaler-check.timer" '^OnCalendar=hourly$'
has "the image service only try-restarts the autoscaler" "$as/nerva-autoscaler-image.service" '^ExecStartPost=-/usr/bin/systemctl try-restart nerva-autoscaler.service$'
hasnt "the image service never plain-restarts it" "$as/nerva-autoscaler-image.service" 'systemctl restart'
n=$((n + 1))
[ "$(grep -n '^ExecStartPost=-.*try-restart' "$as/nerva-autoscaler-image.service" | cut -d: -f1)" -lt "$(grep -n '^ExecStartPost=.*image.sh prune' "$as/nerva-autoscaler-image.service" | cut -d: -f1)" ] || bad "the image service prunes before it restarts the autoscaler"
has "the metadata block drops container traffic to 169.254.169.254" "$as/nerva-ci-metadata-block.service" 'iptables -w -I DOCKER-USER -d 169.254.169.254 -j DROP'
has "the metadata block is enabled at boot" "$as/nerva-ci-metadata-block.service" '^WantedBy=multi-user.target$'
has "provision installs the metadata block" "$as/provision-image.sh" 'nerva-ci-metadata-block.service'
has "provision checks the rule is in place" "$as/provision-image.sh" 'iptables -w -C DOCKER-USER -d 169.254.169.254 -j DROP'
ci_tmpl="$as/cloud-init.tmpl.yaml"
# Fail closed: the agent's start is one shell command, chained after the block unit and the rule check, and a failure powers off.
n=$((n + 1))
chain=$(grep -E '^  - systemctl start nerva-ci-metadata-block.service && iptables -w -C DOCKER-USER -d 169.254.169.254 -j DROP && docker compose -f /root/docker-compose.yml up -d \|\| poweroff$' "$ci_tmpl")
[ -n "$chain" ] || bad "cloud-init does not start the agent only after the metadata block and its check, powering off otherwise"
n=$((n + 1))
[ "$(grep -c 'docker compose' "$ci_tmpl")" = 1 ] || bad "cloud-init starts the agent somewhere other than the guarded line"
n=$((n + 1))
{ [ "$(grep -n 'docker compose' "$ci_tmpl" | head -n 1 | cut -d: -f1)" -lt "$(grep -n 'rm -f /root/docker-compose.yml' "$ci_tmpl" | cut -d: -f1)" ]; } || bad "cloud-init does not delete its copy of the token after it starts the agent"
has "cloud-init deletes the pickled datasource" "$ci_tmpl" 'rm -f .*/var/lib/cloud/instance/obj.pkl'
has "cloud-init deletes its user data" "$ci_tmpl" 'rm -f .*/var/lib/cloud/instance/user-data.txt'

# --- Workflows: every one has a tier, a cloud one never runs for main, none is privileged ----------
for f in .woodpecker/*.yaml; do
    b=$(basename "$f" .yaml)
    n=$((n + 1))
    tier=$(sed -n 's/^  tier: \(cloud\|box\)$/\1/p' "$f")
    [ -n "$tier" ] || { bad "$f has no 'tier: cloud|box' label (decision O6)"; continue; }
    if grep -qE '^\s*privileged:\s*true' "$f"; then bad "$f has a privileged step (decision O4)"; fi
    if [ "$tier" = cloud ]; then
        grep -q "exclude: \[main" "$f" || bad "$f is tier cloud but does not exclude main"
        grep -qE 'branch: main$' "$f" && bad "$f is tier cloud but runs for main"
        twin="$b-main"
        case "$b" in check-packages-[123]) twin=check-packages-main ;; esac
        [ -f ".woodpecker/$twin.yaml" ] || bad "$f has no $twin.yaml for main"
    else
        grep -qE 'branch: main$|event: (cron|manual)' "$f" || bad "$f is tier box but runs nothing on main, cron or manual"
    fi
done
# The twins keep the same job: same ci/woodpecker_step.sh job argument.
for f in .woodpecker/*-main.yaml; do
    b=$(basename "$f" -main.yaml)
    [ -f ".woodpecker/$b.yaml" ] || continue
    [ "$b" != vopr ] || continue # vopr-main is the long search, vopr the short one
    n=$((n + 1))
    a=$(grep -o 'woodpecker_step.sh [a-z0-9-]*[^"]*' ".woodpecker/$b.yaml" | sort -u)
    m=$(grep -o 'woodpecker_step.sh [a-z0-9-]*[^"]*' "$f" | sort -u)
    [ "$a" = "$m" ] || bad "$b.yaml and $b-main.yaml run different jobs: '$a' vs '$m'"
done

# --- check-packages shards: every test class in exactly one shard, run once (NRV-E1244) -----------
shard_table() { # prints "class shard" for each class named in the table
    local s c
    for s in 1 2 3; do
        for c in $(sed -n "s/^package_shards_$s=\"\(.*\)\"/\1/p" "${1:-ci/job.sh}"); do echo "$c $s"; done
    done
}
shards_ok() { # shards_ok TABLE_FILE [TEST_FILE]: NRV-E1244 unless the table partitions the test file's classes
    local classes table c count
    # Every unittest.TestCase class that unittest's own loader finds tests in, own or inherited, whatever its bases.
    classes=$(cd "$(dirname "${2:-.github/scripts/test_package_repos.py}")" && python3 -I -c '
import sys, unittest, importlib.util as u
sys.path.insert(0, ".")
spec = u.spec_from_file_location("t", sys.argv[1])
m = u.module_from_spec(spec)
spec.loader.exec_module(m)
for name, c in vars(m).items():
    if isinstance(c, type) and issubclass(c, unittest.TestCase) and c.__module__ == "t" and unittest.defaultTestLoader.getTestCaseNames(c):
        print(name)
' "$(basename "${2:-.github/scripts/test_package_repos.py}")" | sort)
    [ -n "$classes" ] || { echo "NRV-E1244: no test classes found"; return 1; }
    table=$(shard_table "$1")
    for c in $classes; do
        count=$(awk -v c="$c" '$1 == c' <<< "$table" | wc -l)
        [ "$count" = 1 ] || { echo "NRV-E1244: test class $c is in $count shards of $1, not exactly one"; return 1; }
    done
    for c in $(awk '{print $1}' <<< "$table"); do
        grep -qx "$c" <<< "$classes" || { echo "NRV-E1244: $c in the shard table of $1 is not a class of test_package_repos.py"; return 1; }
    done
}
ok "the shards partition the package test classes" shards_ok ci/job.sh
# A class that is not spelled `class X(Base):` is found too, and so is one that only inherits its tests: a copy of the file with both added.
cp .github/scripts/test_package_repos.py "$tmp/pkg_tests.py"
printf '\nclass Extra(unittest.TestCase, object):\n    def test_x(self):\n        pass\n' >> "$tmp/pkg_tests.py"
refuses "a class with other bases that is in no shard" NRV-E1244 shards_ok ci/job.sh "$tmp/pkg_tests.py"
cp .github/scripts/test_package_repos.py "$tmp/pkg_tests.py"
printf '\nclass ReadyIPv6(Ready):\n    maxDiff = None\n' >> "$tmp/pkg_tests.py"
refuses "a subclass that only inherits its tests, in no shard" NRV-E1244 shards_ok ci/job.sh "$tmp/pkg_tests.py"
sed 's/^package_shards_3="Bucket Publish"/package_shards_3="Bucket"/' ci/job.sh > "$tmp/job_missing.sh"
refuses "a class in no shard" NRV-E1244 shards_ok "$tmp/job_missing.sh"
sed 's/^package_shards_3="Bucket Publish"/package_shards_3="Bucket Publish Happy"/' ci/job.sh > "$tmp/job_twice.sh"
refuses "a class in two shards" NRV-E1244 shards_ok "$tmp/job_twice.sh"
sed 's/^package_shards_3="Bucket Publish"/package_shards_3="Bucket Publish Nonesuch"/' ci/job.sh > "$tmp/job_unknown.sh"
refuses "a name that is no class" NRV-E1244 shards_ok "$tmp/job_unknown.sh"
for s in 1 2 3; do has "check-packages-$s.yaml runs shard $s" ".woodpecker/check-packages-$s.yaml" "check-packages $s"; done
has "check-packages-main.yaml runs all shards on main" .woodpecker/check-packages-main.yaml 'check-packages'
hasnt "no unsharded check-packages for branches" .woodpecker/check-packages-1.yaml 'check-packages"?$'

if [ "$fail" = 0 ]; then echo "autoscaler_test: $n checks OK"; else echo "autoscaler_test: FAILED" >&2; fi
exit "$fail"
