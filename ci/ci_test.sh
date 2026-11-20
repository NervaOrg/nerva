#!/usr/bin/env bash
# Table test for the CI scripts' own refusals and cache rules (NRV-E1201 to E1223, NRV-B1201,
# NRV-W1201 and W1202, docs/ERRORS.md; decision O4). Needs flock and jq. Takes a few seconds;
# touches only a scratch directory. Not covered, as they need a Woodpecker step or a daemon:
# NRV-E1203 (the Docker socket is not mounted), NRV-E1209 and E1210 (Jepsen), the io_uring check on
# a real refusing daemon, woodpecker-bootstrap.sh's NRV-E1213 (its preflight wants root on Ubuntu
# 24.04 first), and "main's cache is not writable in a pipeline for main" when this runs as root
# (root writes through a read-only mode).
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=${CI_TEST_TMP:-$(mktemp -d)}
trap 'rm -rf "$tmp"' EXIT
cd "$root"
fail=0

# want NAME CMD...: runs CMD, which must exit non-zero with CODE in its output.
refuses() { # refuses CODE NAME CMD...
    local code="$1" name="$2" out
    shift 2
    if out=$("$@" 2>&1); then
        echo "FAIL $name: it succeeded, want $code" >&2
        fail=1
    elif ! grep -q "$code" <<<"$out"; then
        echo "FAIL $name: no $code in: $out" >&2
        fail=1
    fi
}
ok() { # ok NAME CMD...
    local name="$1" out
    shift
    if ! out=$("$@" 2>&1); then
        echo "FAIL $name: $out" >&2
        fail=1
    fi
}
is() { # is NAME WANT GOT
    if [ "$2" != "$3" ]; then
        echo "FAIL $1: got '$3', want '$2'" >&2
        fail=1
    fi
}

# --- ci/job.sh: NRV-E1208 ---
refuses NRV-E1208 "job.sh without a job" ci/job.sh
refuses NRV-E1208 "job.sh unknown job" ci/job.sh no-such-job
refuses NRV-E1208 "job.sh demo without a file" ci/job.sh demo
refuses NRV-E1208 "job.sh vopr without a seed" ci/job.sh vopr
refuses NRV-E1208 "job.sh vopr-main lane" ci/job.sh vopr-main nonsense
refuses NRV-E1208 "job.sh fuzz-long MINUTES" env MINUTES=abc ci/job.sh fuzz-long ewah
refuses NRV-E1208 "job.sh fuzz-long without a fuzzer" ci/job.sh fuzz-long

# --- ci/jepsen.sh: NRV-E1206, E1207 ---
jepsen() { JEPSEN_OUT="$tmp/jepsen-out" env "$@" bash ci/jepsen.sh; }
refuses NRV-E1206 "jepsen args" jepsen 'ARGS=test; rm -rf /'
refuses NRV-E1206 "jepsen args newline" jepsen $'ARGS=test\nx'
refuses NRV-E1206 "jepsen TEETH" jepsen TEETH=maybe
refuses NRV-E1206 "jepsen JEPSEN_LAZYFS_PATCH" jepsen JEPSEN_LAZYFS_PATCH=maybe
refuses NRV-E1206 "jepsen --test-count" jepsen 'ARGS=test --test-count 5'
refuses NRV-E1206 "jepsen --time-limit" jepsen 'ARGS=test --time-limit 5000'
bin="$tmp/bin"
mkdir "$bin"
for t in mkdir dirname git sed cat; do ln -s "$(command -v $t)" "$bin/$t"; done
refuses NRV-E1207 "jepsen without gnuplot" env PATH="$bin" JEPSEN_OUT="$tmp/out2" "$(command -v bash)" ci/jepsen.sh

# --- ci/io_uring_check.sh: NRV-E1201 ---
refuses NRV-E1201 "io_uring refused" ci/io_uring_check.sh --pretend-refused
mkdir -p "$tmp/badpy"
printf '#!/bin/sh\necho "Traceback: boom" >&2\nexit 1\n' >"$tmp/badpy/python3"
chmod +x "$tmp/badpy/python3"
refuses NRV-E1223 "io_uring probe that breaks (exit 1)" env PATH="$tmp/badpy:$PATH" ci/io_uring_check.sh
refuses "probe itself failed (Traceback: boom)" "io_uring probe's error is in the message" env PATH="$tmp/badpy:$PATH" ci/io_uring_check.sh

# --- ci/docker_client.sh: NRV-E1204, E1205 ---
mkdir -p "$tmp/dc/src/docker"
printf '#!/bin/sh\necho docker\n' >"$tmp/dc/src/docker/docker"
chmod +x "$tmp/dc/src/docker/docker"
tar -czf "$tmp/dc/docker-9.tgz" -C "$tmp/dc/src" docker
dsha=$(sha256sum "$tmp/dc/docker-9.tgz" | cut -d ' ' -f 1)
refuses NRV-E1204 "docker client arch" env CI_ARCH=aarch64 ci/docker_client.sh 9 "$dsha" "$tmp/dc/c1"
refuses NRV-E1205 "docker client sha" env CI_ARCH=x86_64 CI_DOCKER_CLIENT_URL="file://$tmp/dc/docker-9.tgz" \
    CI_DOCKER_BIN_DIR="$tmp/dc/bin" ci/docker_client.sh 9 "$(printf '%064d' 0)" "$tmp/dc/c2"
ok "docker client installs" env CI_ARCH=x86_64 CI_DOCKER_CLIENT_URL="file://$tmp/dc/docker-9.tgz" \
    CI_DOCKER_BIN_DIR="$tmp/dc/bin" ci/docker_client.sh 9 "$dsha" "$tmp/dc/c3"
[ -x "$tmp/dc/bin/docker" ] || { echo "FAIL docker client: no binary" >&2; fail=1; }
# A cached archive that differs from its pin is never used, and is fetched again.
echo junk >"$tmp/dc/c3/docker-9.tgz"
ok "docker client replaces a bad cached archive" env CI_ARCH=x86_64 CI_DOCKER_CLIENT_URL="file://$tmp/dc/docker-9.tgz" \
    CI_DOCKER_BIN_DIR="$tmp/dc/bin2" ci/docker_client.sh 9 "$dsha" "$tmp/dc/c3"
is "docker client cache repaired" "$dsha" "$(sha256sum "$tmp/dc/c3/docker-9.tgz" | cut -d ' ' -f 1)"

# --- ci/lib.sh: ci_redact ---
key=$(printf 'ab%.0s' {1..32})
out=$(env -u GITHUB_ACTIONS bash -c ". ci/lib.sh; ci_mask $key; echo \"key $key and ${key:0:16}x\" | ci_redact")
is "ci_redact" "key *** and ***x" "$out"
out=$(env -u GITHUB_ACTIONS bash -c ". ci/lib.sh; ci_mask $key; echo \"key ${key^^}\" | ci_redact")
is "ci_redact is case-insensitive" "key ***" "$out"
is "ci_redact without a mask" "plain" "$(env -u GITHUB_ACTIONS bash -c '. ci/lib.sh; echo plain | ci_redact')"
refuses NRV-B1201 "ci_redact refuses a value that is not hex" env -u GITHUB_ACTIONS bash -c '. ci/lib.sh; ci_mask not-hex; echo x | ci_redact'

# --- ci/lib.sh: ci_run_timed, NRV-E1215 ---
timed() { env -u GITHUB_ACTIONS CI_KILL_AFTER=1 bash -c '. ci/lib.sh; ci_run_timed "$@"' _ "$@"; }
refuses NRV-E1215 "a job past its time limit (TERM)" timed stubjob 1 sleep 30
refuses NRV-E1215 "a job that ignores TERM (killed)" timed stubjob 1 sh -c 'trap "" TERM; sleep 30'
ok "a job within its limit" timed stubjob 5 true
out=$(timed stubjob 30 sh -c 'kill -9 $$' 2>&1) || true
grep -q NRV-E1222 <<<"$out" || { echo "FAIL kill -9: no NRV-E1222 in: $out" >&2; fail=1; }
if grep -q NRV-E1215 <<<"$out"; then echo "FAIL kill -9: reported as NRV-E1215: $out" >&2; fail=1; fi
out=$(timed stubjob 30 sh -c 'exit 124' 2>&1) || true
if grep -q 'NRV-E12' <<<"$out"; then echo "FAIL exit 124 by itself: reported: $out" >&2; fail=1; fi
rc=0
timed stubjob 5 sh -c 'exit 7' >/dev/null 2>&1 || rc=$?
is "a failing job keeps its own status" 7 "$rc"
refuses NRV-E1208 "CI_STEP_MINUTES not a number" env CI_STEP_MINUTES=soon ci/woodpecker_step.sh check

# --- ci/cache.sh ---
. ci/cache.sh
is "branch key differs" yes "$([ "$(ci_branch_key a/b)" != "$(ci_branch_key a_b)" ] && echo yes)"
is "branch key is a plain name" yes "$([[ "$(ci_branch_key 'feat/x y;..')" =~ ^b-[A-Za-z0-9._-]+$ ]] && echo yes)"
is "branch key is stable" "$(ci_branch_key main2)" "$(ci_branch_key main2)"

c="$tmp/cache"
mkdir -p "$c/main/zig" "$c/main/zig-local" "$c/main/tools" "$c/branches"
refuses NRV-E1202 "cache not laid out" ci_cache_check branch "$tmp/nowhere"
# As root the main directory is always writable, so a branch pipeline that mounted it read-only
# cannot be told apart here; a writable one is what a branch must be refused.
refuses NRV-E1202 "branch with main writable" ci_cache_check branch "$c"
ok "main with main writable" ci_cache_check main "$c"
if [ "$(id -u)" != 0 ]; then
    chmod a-w "$c/main"
    refuses NRV-E1202 "main with main read-only" ci_cache_check main "$c"
    ok "branch with main read-only" ci_cache_check branch "$c"
    chmod u+w "$c/main"
fi

# A branch's zig/p is a plain copy of main's (not a link, and writing it leaves main's alone);
# main's zig-local and the rest of its zig/, which a build may be writing, are not copied.
mkdir -p "$c/main/zig/p"
echo seed >"$c/main/zig-local/entry"
echo seed >"$c/main/zig/entry"
echo seed >"$c/main/zig/p/entry"
(
    . ci/cache.sh
    ci_branch_prepare "$c" feature/one
    echo "$CI_BRANCH_DIR" >"$tmp/dir1"
)
d1=$(cat "$tmp/dir1")
is "branch cache seeded" seed "$(cat "$d1/zig/p/entry")"
is "main's other zig files are not copied" "p" "$(ls -A "$d1/zig")"
is "main's zig-local is not copied" "" "$(ls -A "$d1/zig-local")"
is "branch cache is a copy, not a link" 1 "$(stat -c %h "$d1/zig/p/entry")"
echo changed >>"$d1/zig/p/entry"
is "main untouched by a branch" seed "$(cat "$c/main/zig/p/entry")"
# Main's cache over the seed limit: the branch starts empty (du rounds up to a whole GiB).
(
    . ci/cache.sh
    CI_BRANCH_SEED_MAX_GIB=0 ci_branch_prepare "$c" feature/two 2>/dev/null
    echo "$CI_BRANCH_DIR" >"$tmp/dir2"
)
is "oversize main is not copied" "" "$(ls -A "$(cat "$tmp/dir2")/zig")"
# A failed copy leaves no partial zig/p (a stub cp early in PATH that half-copies and fails, so
# the case runs as root too).
mkdir -p "$tmp/badcp"
printf '#!/bin/sh\nfor a; do last=$a; done\nmkdir -p "${last}p"\necho "cp: stub: no space left on device" >&2\nexit 1\n' >"$tmp/badcp/cp"
chmod +x "$tmp/badcp/cp"
out=$(
    . ci/cache.sh
    PATH="$tmp/badcp:$PATH" ci_branch_prepare "$c" feature/badseed 2>&1
    echo "$CI_BRANCH_DIR" >"$tmp/dirbs"
)
grep -q "seed copy failed: branch .*no space left on device" <<<"$out" || { echo "FAIL failed seed: no message in: $out" >&2; fail=1; }
is "a failed seed copy leaves no zig/p" "" "$(ls -A "$(cat "$tmp/dirbs")/zig")"
# Bounded: only the newest CI_BRANCH_CACHES others stay, and one a job holds is never removed.
for i in 1 2 3 4 5 6; do
    mkdir "$c/branches/b-old$i-0000000$i"
    touch -d "$((i + 1)) minutes ago" "$c/branches/b-old$i-0000000$i"
done
flock -s "$c/branches/b-old6-00000006.lock" sleep 20 &
holder=$!
sleep 0.3
(
    . ci/cache.sh
    CI_BRANCH_CACHES=2 ci_branch_prepare "$c" feature/three
)
# The bound counts the job's own cache (feature/three): it and the newest other, feature/two, are
# the two places; old6 is the oldest but a job holds it, so it stays as well.
is "old branch caches pruned, the one in use kept" "yes" "$([ -d "$c/branches/b-old6-00000006" ] && [ ! -d "$c/branches/b-old5-00000005" ] && [ ! -d "$c/branches/b-old1-00000001" ] && echo yes)"
is "the bound is at most CI_BRANCH_CACHES, the job's own included, and what is in use" 3 "$(find "$c/branches" -maxdepth 1 -type d -name 'b-*' | wc -l)"
pkill -P "$holder" 2>/dev/null || true; kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true

# A prune never unlinks a branch's lock file: a job that opened it first would then hold a lock on
# an inode that no later prune opens.
mkdir "$c/branches/b-gone-00000099"
touch -d "40 days ago" "$c/branches/b-gone-00000099"
: >"$c/branches/b-gone-00000099.lock"
(
    . ci/cache.sh
    ci_branch_prepare "$c" feature/four
)
is "old branch cache removed" no "$([ -d "$c/branches/b-gone-00000099" ] && echo yes || echo no)"
is "its lock file stays" yes "$([ -f "$c/branches/b-gone-00000099.lock" ] && echo yes || echo no)"
# NRV-W1202: the branches' lock stays busy, so the branch's cache is made without seeding.
flock -x "$c/branches/.lock" sleep 20 &
holder=$!
sleep 0.3
out=$(
    . ci/cache.sh
    CI_LOCK_WAIT=1 ci_branch_prepare "$c" feature/five 2>&1
    echo "dir=$CI_BRANCH_DIR"
)
pkill -P "$holder" 2>/dev/null || true; kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
grep -q NRV-W1202 <<<"$out" || { echo "FAIL branch lock busy: no NRV-W1202 in: $out" >&2; fail=1; }
key5=$(. ci/cache.sh && ci_branch_key feature/five)
is "unlocked branch cache is made" yes "$([ -d "$c/branches/$key5/zig-local" ] && echo yes)"
# A seed whose directory a job without the lock made meanwhile replaces nothing and nests nothing.
(
    . ci/cache.sh
    key=$(ci_branch_key feature/six)
    cp() { mkdir -p "$c/branches/$key/zig"; command cp "$@"; } # the other job, mid-seed
    ci_branch_prepare "$c" feature/six
    echo "$CI_BRANCH_DIR" >"$tmp/dir6"
)
d6=$(cat "$tmp/dir6")
is "a seed does not nest in an existing cache" "" "$(find "$d6" -name '*.partial.*')"
is "no seed directory is left behind" "" "$(find "$c/branches" -maxdepth 1 -name '*.partial.*')"

# NRV-E1214: a branch's cache path that is a regular file is refused, not used, and the branches'
# lock is not kept (a caller that went on would hold every branch job up).
branch_file() {
    . ci/cache.sh
    ci_branch_prepare "$c" feature/seven
}
seven=$(. ci/cache.sh; ci_branch_key feature/seven)
: >"$c/branches/$seven"
refuses NRV-E1214 "branch cache path is a file" branch_file
is "the branches' lock is released after NRV-E1214" free "$(
    . ci/cache.sh
    ci_branch_prepare "$c" feature/seven >/dev/null 2>&1 || true
    flock -x -n "$c/branches/.lock" true && echo free || echo held
)"
rm -f "$c/branches/$seven"
# The same on the NRV-W1202 path: the lock stays busy, $dir is a file.
eight=$(. ci/cache.sh; ci_branch_key feature/eight)
: >"$c/branches/$eight"
flock -x "$c/branches/.lock" sleep 20 &
holder=$!
sleep 0.3
branch_file_unlocked() {
    . ci/cache.sh
    CI_LOCK_WAIT=1 ci_branch_prepare "$c" feature/eight
}
refuses NRV-E1214 "branch cache path is a file, branches' lock busy" branch_file_unlocked
pkill -P "$holder" 2>/dev/null || true; kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
rm -f "$c/branches/$eight"

# --- ops/ci/io_uring_probe.sh: the probe's perl never dies (exit 255); NRV-E1201 and E1211 ---
if command -v perl >/dev/null; then
    rc=0
    bash ops/ci/io_uring_probe.sh local >/dev/null 2>&1 || rc=$?
    is "io_uring probe runs on the host (exit 0 or 1, not 255)" yes "$([ "$rc" -le 1 ] && echo yes || echo "no, $rc")"
else
    echo "ci_test: no perl: the io_uring probe is not run on the host" >&2
fi
# With no Docker here, a stub stands in for it: pull and run succeed, fail or die as set.
mkdir "$tmp/fakedocker"
cat >"$tmp/fakedocker/docker" <<'EOS'
#!/bin/sh
case "$1" in
    pull) [ "$FAKE_PULL" != down ] || { echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?" >&2; exit 1; }
        [ "$FAKE_PULL" = ok ] || { echo "toomanyrequests: pull rate limit" >&2; exit 1; } ;;
    run) echo "${FAKE_REASON:-}" >&2; exit "$FAKE_RUN" ;;
esac
EOS
chmod +x "$tmp/fakedocker/docker"
probe() { env PATH="$tmp/fakedocker:$PATH" "$@" bash ops/ci/io_uring_probe.sh; }
refuses NRV-E1211 "probe: image not pulled" probe FAKE_PULL=no FAKE_RUN=0
refuses "Operation not permitted" "probe: reason shown" probe FAKE_PULL=ok FAKE_RUN=1 FAKE_REASON="Operation not permitted"
refuses "kernel.io_uring_disabled" "probe: other cause named" probe FAKE_PULL=ok FAKE_RUN=1
refuses "daemon may be down" "probe: daemon down named" probe FAKE_PULL=down FAKE_RUN=0
refuses NRV-E1212 "probe: perl died" probe FAKE_PULL=ok FAKE_RUN=255 FAKE_REASON="perl: not found"
rc=0
probe FAKE_PULL=ok FAKE_RUN=255 >/dev/null 2>&1 || rc=$?
is "probe: a broken probe exits 3" 3 "$rc"
rc=0
probe FAKE_PULL=ok FAKE_RUN=1 >/dev/null 2>&1 || rc=$?
is "probe: a refusal exits 1" 1 "$rc"
rc=0
probe FAKE_PULL=no FAKE_RUN=0 >/dev/null 2>&1 || rc=$?
is "probe: a failed pull exits 2" 2 "$rc"
ok "probe: io_uring allowed" probe FAKE_PULL=ok FAKE_RUN=0

# NRV-E1213: nerva-woodpecker.sh copied alone (no io_uring_probe.sh beside it) says so, before it
# touches anything. A stub `id` stands in for root.
mkdir "$tmp/alone" "$tmp/fakeroot"
cp ops/ci/nerva-woodpecker.sh "$tmp/alone/"
printf '#!/bin/sh\necho 0\n' >"$tmp/fakeroot/id"
chmod +x "$tmp/fakeroot/id"
refuses NRV-E1213 "nerva-woodpecker.sh host without the probe" env PATH="$tmp/fakeroot:$PATH" bash "$tmp/alone/nerva-woodpecker.sh" host
# woodpecker-bootstrap.sh has the same check in its preflight (and CI_SECCOMP=no to skip it); it
# needs root on Ubuntu 24.04 first, so it is not run here.

# --- ops/ci/nerva-woodpecker.sh: host, all the way to its OK line, and NRV-E1216 to E1221 ---
# Stubs stand in for docker, id (root), install (-o and -g need root), modprobe and curl; the cache
# root, /dev and /etc/modules-load.d are scratch directories (NERVA_CI_*).
hb="$tmp/hostbin"
mkdir "$hb"
printf '#!/bin/sh\necho 0\n' >"$hb/id"
printf '#!/bin/sh\nexit 1\n' >"$hb/modprobe"
cat >"$hb/install" <<'EOS'
#!/bin/bash
a=()
while [ $# -gt 0 ]; do
    case "$1" in -o | -g) shift ;; *) a+=("$1") ;; esac
    shift
done
exec /usr/bin/install "${a[@]}"
EOS
cat >"$hb/docker" <<'EOS'
#!/bin/sh
case "$1" in
    info) [ "$FAKE_DOCKER" != down ] || exit 1 ;;
    ps) [ "$FAKE_DOCKER" = noagent ] || echo woodpecker-agent ;;
    pull | run) exit 0 ;;
esac
EOS
cat >"$hb/curl" <<'EOS'
#!/bin/bash
# The Woodpecker API: FAKE_API holds words that make one call fail or answer differently.
method=GET
url=
while [ $# -gt 0 ]; do
    case "$1" in -X) method="$2"; shift ;; -H | --data) shift ;; -*) ;; *) url="$1" ;; esac
    shift
done
has() { case " $FAKE_API " in *" $1 "*) return 0 ;; esac; return 1; }
case "$method $url" in
    "GET "*/api/user) has badtoken && exit 22; echo '{}' ;;
    "GET "*/api/repos/lookup/*) has notenabled && exit 22; echo '{"id":7}' ;;
    "GET "*/api/user/repos*) has invisible && echo '[]' || echo '[{"full_name":"o/n","forge_remote_id":"9"}]' ;;
    "POST "*/api/repos*) has noenable && exit 22; echo '{"id":7}' ;;
    "PATCH "*/api/repos/7) has refuse && exit 22; echo '{}' ;;
    "GET "*/api/repos/7)
        if has nottaken; then
            echo '{"allow_pr":true,"require_approval":"forks","timeout":60,"trusted":{"volumes":true,"network":true,"security":false}}'
        else
            echo '{"allow_pr":false,"require_approval":"forks","timeout":360,"trusted":{"volumes":true,"network":true,"security":false}}'
        fi ;;
    *) echo "curl stub: $method $url" >&2; exit 22 ;;
esac
EOS
chmod +x "$hb"/*
mkdir -p "$tmp/hostdev" "$tmp/nodev" "$tmp/hostmods"
: >"$tmp/hostdev/fuse"
nw() { # nw VAR=VALUE... -- ARGS...: runs the real script with the stubs first in PATH
    local vars=()
    while [ "$1" != -- ]; do vars+=("$1"); shift; done
    shift
    env PATH="$hb:$PATH" NERVA_CI_CACHE_ROOT="$tmp/hostcache" NERVA_CI_DEV="$tmp/hostdev" \
        NERVA_CI_MODULES_DIR="$tmp/hostmods" "${vars[@]}" bash ops/ci/nerva-woodpecker.sh "$@"
}
out=$(nw FAKE_DOCKER=ok -- host 2>&1) || { echo "FAIL host on a fresh box: $out" >&2; fail=1; }
grep -q 'nerva-woodpecker: OK host' <<<"$out" || { echo "FAIL host on a fresh box: no OK line in: $out" >&2; fail=1; }
is "host makes the cache directories" yes "$([ -d "$tmp/hostcache/main" ] && [ -d "$tmp/hostcache/branches" ] && [ -d "$tmp/hostcache/jepsen" ] && echo yes)"
mkdir "$tmp/hostcache/zig"
out=$(nw FAKE_DOCKER=ok -- host 2>&1) || { echo "FAIL host run again: $out" >&2; fail=1; }
grep -q 'old layout (zig )' <<<"$out" || { echo "FAIL host run again: the old layout is not noted in: $out" >&2; fail=1; }
grep -q 'nerva-woodpecker: OK host' <<<"$out" || { echo "FAIL host run again: no OK line in: $out" >&2; fail=1; }
refuses NRV-E1216 "host: docker is down" nw FAKE_DOCKER=down -- host
refuses NRV-E1216 "host: no agent container" nw FAKE_DOCKER=noagent -- host
nodocker="$tmp/nodocker"
mkdir "$nodocker"
for t in dirname readlink; do ln -s "$(command -v $t)" "$nodocker/$t"; done
# A stub id stands in for root, so the root check passes and the docker check is what refuses.
printf '#!/bin/sh\necho 0\n' >"$nodocker/id"
chmod +x "$nodocker/id"
refuses NRV-E1216 "host: no docker" env PATH="$nodocker" "$(command -v bash)" ops/ci/nerva-woodpecker.sh host
refuses NRV-E1217 "host: no /dev/fuse" nw FAKE_DOCKER=ok NERVA_CI_DEV="$tmp/nodev" -- host
mkdir "$tmp/notroot"
printf '#!/bin/sh\necho 1000\n' >"$tmp/notroot/id"
chmod +x "$tmp/notroot/id"
refuses NRV-E1221 "host: not root" env PATH="$tmp/notroot:$PATH" bash ops/ci/nerva-woodpecker.sh host
refuses NRV-E1221 "usage" nw FAKE_DOCKER=ok -- nonsense
refuses NRV-E1221 "repo: a bad name" nw FAKE_DOCKER=ok -- repo not-a-name
repo_env=(WOODPECKER_SERVER=http://woodpecker.invalid WOODPECKER_TOKEN=t)
refuses NRV-E1218 "repo: token refused" nw "${repo_env[@]}" FAKE_API=badtoken -- repo o/n
refuses NRV-E1219 "repo: not visible" nw "${repo_env[@]}" FAKE_API="notenabled invisible" -- repo o/n
refuses NRV-E1219 "repo: could not enable" nw "${repo_env[@]}" FAKE_API="notenabled noenable" -- repo o/n
refuses NRV-E1220 "repo: settings refused" nw "${repo_env[@]}" FAKE_API=refuse -- repo o/n
refuses NRV-E1220 "repo: settings did not take" nw "${repo_env[@]}" FAKE_API=nottaken -- repo o/n
out=$(nw "${repo_env[@]}" FAKE_API="notenabled" -- repo o/n 2>&1) || { echo "FAIL repo: $out" >&2; fail=1; }
grep -q 'nerva-woodpecker: OK repo o/n' <<<"$out" || { echo "FAIL repo: no OK line in: $out" >&2; fail=1; }

# ci_main_prune: empties main's Zig caches when nobody holds them; NRV-W1202 when others do.
echo x >"$c/main/zig-local/entry"
touch "$c/main/.lock"
(
    . ci/cache.sh
    exec 9<"$c/main/.lock"
    CI_PRUNE_WAIT=1 ci_main_prune "$c" 99999999
)
is "main pruned when idle" "" "$(ls -A "$c/main/zig-local")"
echo x >"$c/main/zig-local/entry"
flock -s "$c/main/.lock" sleep 20 &
holder=$!
sleep 0.3
out=$(
    . ci/cache.sh
    exec 9<"$c/main/.lock"
    CI_PRUNE_WAIT=1 ci_main_prune "$c" 99999999 2>&1
)
pkill -P "$holder" 2>/dev/null || true; kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
grep -q NRV-W1202 <<<"$out" || { echo "FAIL prune busy: no NRV-W1202 in: $out" >&2; fail=1; }
is "main kept when busy" entry "$(ls "$c/main/zig-local")"
# Space is no longer low once the wait ends: not pruned, and no warning even though the lock is busy.
flock -s "$c/main/.lock" sleep 20 &
holder=$!
sleep 0.3
out=$(
    . ci/cache.sh
    exec 9<"$c/main/.lock"
    CI_PRUNE_WAIT=1 ci_main_prune "$c" 0 2>&1
)
pkill -P "$holder" 2>/dev/null || true; kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
if grep -q NRV-W1202 <<<"$out"; then echo "FAIL prune busy but space free: NRV-W1202 in: $out" >&2; fail=1; fi
is "main kept when space is free again" entry "$(ls "$c/main/zig-local")"
(
    . ci/cache.sh
    exec 9<"$c/main/.lock"
    CI_PRUNE_WAIT=1 ci_main_prune "$c" 0 >/dev/null
)
is "main kept when idle and space is free" entry "$(ls "$c/main/zig-local")"

# The step's own sequence (ci_main_prepare: lock, prune, then ownership): after a prune main's
# directories belong to the job's user. As root the user is `nobody`; as another user the check is
# trivially true (the prune recreates the directories as that user), so only root proves the order.
if [ "$(id -u)" = 0 ]; then ou=nobody; else ou=$(id -un); fi
og=$(id -gn "$ou")
echo x >"$c/main/zig-local/entry"
(
    . ci/cache.sh
    CI_PRUNE_WAIT=1 ci_main_prepare "$c" "$ou" "$og" yes 99999999 >/dev/null
)
is "prepare: main pruned" "" "$(ls -A "$c/main/zig-local")"
is "prepare: zig owned by the job's user after a prune" "$ou" "$(stat -c %U "$c/main/zig")"
is "prepare: zig-local owned by the job's user after a prune" "$ou" "$(stat -c %U "$c/main/zig-local")"
is "prepare: tools owned by the job's user" "$ou" "$(stat -c %U "$c/main/tools")"

# --- ci/install_zig.sh: the toolchain archive is checked on every use; only main writes it ---
z="$tmp/zrepo"
mkdir -p "$z/ci" "$z/zig"
cp ci/install_zig.sh ci/lib.sh "$z/ci/"
asha=$(printf 'stub archive' | sha256sum | cut -d ' ' -f 1)
{
    echo '#!/bin/sh'
    echo 'set -eu'
    echo ": <<'PINS'"
    for a in x86_64 aarch64; do for o in linux macos; do
        echo "https://example.invalid/0.0.0/zig-$a-$o-0.0.0.tar.xz $asha"
    done; done
    echo PINS
    # The stub of download.sh: unpacks nothing, but like the real one it checks a present archive
    # against the pin and replaces a bad one, and leaves the archive in zig/cache.
    cat <<EOS
a=\$(ls zig/cache 2>/dev/null | head -1 || true)
if [ -z "\$a" ] || [ "\$(sha256sum "zig/cache/\$a" | cut -d ' ' -f 1)" != "$asha" ]; then
    mkdir -p zig/cache
    for f in zig/cache/*; do [ ! -f "\$f" ] || rm -f "\$f"; done
    case "\$(uname -m)" in arm64 | aarch64) arch=aarch64 ;; *) arch=x86_64 ;; esac
    case "\$(uname)" in Darwin) os=macos ;; *) os=linux ;; esac
    printf 'stub archive' > "zig/cache/zig-\$arch-\$os-0.0.0.tar.xz"
fi
mkdir -p zig/lib
printf '#!/bin/sh\necho 0.0.0\n' > zig/zig
chmod +x zig/zig
EOS
} >"$z/zig/download.sh"
chmod +x "$z/zig/download.sh"
tc="$tmp/toolchains"
run_zig() { (cd "$z" && env CI_CACHE_SHARED=1 CI_TOOLCHAIN_DIR="$tc" "$@" ci/install_zig.sh); }
ok "install_zig cold, main writes the archive" run_zig CI_TOOLCHAIN_WRITE=1
is "toolchain archive named by its sha256" "yes" "$([ "$(sha256sum "$tc/$asha.tar.xz" | cut -d ' ' -f 1)" = "$asha" ] && echo yes)"
echo tampered >"$tc/$asha.tar.xz"
out=$(run_zig CI_TOOLCHAIN_WRITE=0 2>&1) || { echo "FAIL install_zig on a branch: $out" >&2; fail=1; }
grep -q NRV-W1201 <<<"$out" || { echo "FAIL install_zig: no NRV-W1201 in: $out" >&2; fail=1; }
is "a branch never replaces main's toolchain" tampered "$(cat "$tc/$asha.tar.xz")"
ok "install_zig on main replaces a bad archive" run_zig CI_TOOLCHAIN_WRITE=1
is "main's toolchain repaired" "yes" "$([ "$(sha256sum "$tc/$asha.tar.xz" | cut -d ' ' -f 1)" = "$asha" ] && echo yes)"

if [ "$fail" = 0 ]; then echo "ci_test: ok"; fi
exit "$fail"
