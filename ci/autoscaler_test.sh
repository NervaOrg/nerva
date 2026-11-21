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
if [ -f "$f" ]; then cat "$f"; else printf '{}\n200'; fi
EOF
chmod +x "$stubs"/*
export STUB_LOG="$tmp/log" STUB_API="$tmp/api" STUB_HELP="$tmp/help.txt"
mkdir -p "$STUB_LOG" "$STUB_API"
for f in max-agents agent-idle-timeout workflows-per-agent cloudinit-template hetznercloud-server-type hetznercloud-image hetznercloud-labels pool-id agent-labels agent-image server-token hetznercloud-api-token; do echo "--$f x" >> "$STUB_HELP"; done

uid=$(id -u)
export NERVA_CI_ROOT_UID=$uid NERVA_AS_NO_SYSTEMD=1 PATH="$stubs:$PATH"
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
sf() { ( tool=test; export tool; . "$as/lib.sh"; secret_file "$@" ); }
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
refuses "a shared-vCPU server type" NRV-E1238 env NERVA_AS_SERVER_TYPE=cx32 bash "$as/nerva-autoscaler.sh" install
refuses "a cap of 0" NRV-E1238 env NERVA_AS_MAX=0 bash "$as/nerva-autoscaler.sh" install
refuses "a cap over the maximum" NRV-E1238 env NERVA_AS_MAX=17 bash "$as/nerva-autoscaler.sh" install
refuses "an idle time in hours" NRV-E1238 env NERVA_AS_IDLE=2h bash "$as/nerva-autoscaler.sh" install
refuses "a plain http server" NRV-E1238 env NERVA_AS_SERVER=http://ci.example.org bash "$as/nerva-autoscaler.sh" install
rm -f "$etc/autoscaler.conf"
refuses "an autoscaler without a flag the script passes" NRV-E1240 env STUB_HELP="$tmp/nohelp.txt" bash "$as/nerva-autoscaler.sh" install
echo "--max-agents" > "$tmp/nohelp.txt"
rm -f "$etc/autoscaler.conf"
ok "install" inst
has "conf has the server" "$etc/autoscaler.conf" '^AS_SERVER=https://ci.example.org$'
has "conf derives the gRPC address" "$etc/autoscaler.conf" '^AS_GRPC=ci.example.org:9000$'
has "conf has the default cap" "$etc/autoscaler.conf" '^AS_MAX=4$'
has "conf has the dedicated type" "$etc/autoscaler.conf" '^AS_SERVER_TYPE=ccx33$'
hasnt "conf holds no secret" "$etc/autoscaler.conf" "SECRET"
for f in nerva-autoscaler.sh nerva-autoscaler-image.sh provision-image.sh lib.sh cloud-init.tmpl.yaml; do
    n=$((n + 1))
    [ -f "$tmp/lib/$f" ] || bad "install did not copy $f"
done
for f in nerva-autoscaler.service nerva-autoscaler-image.service nerva-autoscaler-image.timer; do
    n=$((n + 1))
    [ -f "$tmp/units/$f" ] || bad "install did not write $f"
done
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
has "run caps the servers" "$a" 'WOODPECKER_MAX_AGENTS=2'
has "run names the snapshot" "$a" 'WOODPECKER_HETZNERCLOUD_IMAGE=4242'
has "run uses a dedicated type in the box's location" "$a" 'WOODPECKER_HETZNERCLOUD_SERVER_TYPE=ccx33:fsn1'
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
refuses "a keep count of 0" NRV-E1238 env NERVA_AS_KEEP=0 bash "$img" prune
rm -f "$etc/hcloud.token"
refuses "build without the token file" NRV-E1237 env NERVA_CI_CACHE_ROOT="$tmp/noseed" bash "$img" build

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
has "the unit runs the installed script" "$as/nerva-autoscaler.service" 'ExecStart=/usr/local/lib/nerva-ci/nerva-autoscaler.sh run'

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
shards_ok() { # shards_ok TABLE_FILE: NRV-E1244 unless the table partitions the file's classes
    local classes table c count
    classes=$(sed -n 's/^class \([A-Za-z0-9_]*\)(Base):.*/\1/p' .github/scripts/test_package_repos.py | sort)
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
