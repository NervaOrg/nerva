#!/usr/bin/env bash
# Table test for the CI scripts' own refusals and cache rules (NRV-E1201 to E1227, NRV-B1201,
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
mkdir -m 0700 "$c/locks"
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
printf '#!/bin/sh\nfor a; do last=$a; done\nmkdir -p "${last}p"\necho "cp: first: a first line" >&2\necho "cp: stub: no space left on device" >&2\nexit 1\n' >"$tmp/badcp/cp"
chmod +x "$tmp/badcp/cp"
out=$(
    . ci/cache.sh
    PATH="$tmp/badcp:$PATH" ci_branch_prepare "$c" feature/badseed 2>&1
    echo "$CI_BRANCH_DIR" >"$tmp/dirbs"
)
grep -q "seed copy failed: branch .*no space left on device" <<<"$out" || { echo "FAIL failed seed: no message in: $out" >&2; fail=1; }
if grep -q "a first line" <<<"$out"; then echo "FAIL failed seed: the first stderr line is in the message, want the last: $out" >&2; fail=1; fi
is "a failed seed copy leaves no zig/p" "" "$(ls -A "$(cat "$tmp/dirbs")/zig")"
# A cp that fails without a word: the message still says something.
mkdir -p "$tmp/quietcp"
printf '#!/bin/sh\nexit 1\n' >"$tmp/quietcp/cp"
chmod +x "$tmp/quietcp/cp"
out=$(
    . ci/cache.sh
    PATH="$tmp/quietcp:$PATH" ci_branch_prepare "$c" feature/quietseed 2>&1
)
grep -q "seed copy failed: branch .*starts empty (no message)" <<<"$out" || { echo "FAIL silent failed seed: no 'no message' in: $out" >&2; fail=1; }
is "a failed seed copy leaves no file of its own in the branch cache" "" "$(find "$(cat "$tmp/dirbs")" -type f)"
# Bounded: only the newest CI_BRANCH_CACHES others stay, and one a job holds is never removed.
for i in 1 2 3 4 5 6; do
    mkdir "$c/branches/b-old$i-0000000$i"
    touch -d "$((i + 1)) minutes ago" "$c/branches/b-old$i-0000000$i"
done
setsid flock -o -s "$c/locks/b-old6-00000006.lock" sleep 20 &
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
kill -- -"$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true

# A prune never unlinks a branch's lock file: a job that opened it first would then hold a lock on
# an inode that no later prune opens.
mkdir "$c/branches/b-gone-00000099"
touch -d "40 days ago" "$c/branches/b-gone-00000099"
: >"$c/locks/b-gone-00000099.lock"
(
    . ci/cache.sh
    ci_branch_prepare "$c" feature/four
)
is "old branch cache removed" no "$([ -d "$c/branches/b-gone-00000099" ] && echo yes || echo no)"
is "its lock file stays" yes "$([ -f "$c/locks/b-gone-00000099.lock" ] && echo yes || echo no)"
# NRV-W1202: the branches' lock stays busy, so the branch's cache is made without seeding.
setsid flock -o -x "$c/locks/branches.lock" sleep 20 &
holder=$!
sleep 0.3
out=$(
    . ci/cache.sh
    CI_LOCK_WAIT=1 ci_branch_prepare "$c" feature/five 2>&1
    echo "dir=$CI_BRANCH_DIR"
)
kill -- -"$holder" 2>/dev/null || true
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
    flock -x -n "$c/locks/branches.lock" true && echo free || echo held
)"
rm -f "$c/branches/$seven"
# The same on the NRV-W1202 path: the lock stays busy, $dir is a file.
eight=$(. ci/cache.sh; ci_branch_key feature/eight)
: >"$c/branches/$eight"
setsid flock -o -x "$c/locks/branches.lock" sleep 20 &
holder=$!
sleep 0.3
branch_file_unlocked() {
    . ci/cache.sh
    CI_LOCK_WAIT=1 ci_branch_prepare "$c" feature/eight
}
refuses NRV-E1214 "branch cache path is a file, branches' lock busy" branch_file_unlocked
kill -- -"$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
rm -f "$c/branches/$eight"

# NRV-E1225: a branch's own cache lock held exclusively does not hold a step up for good, and the
# branches' lock is not kept. Lock files are the step's own, 0600.
nine=$(. ci/cache.sh; ci_branch_key feature/nine)
: >"$c/locks/$nine.lock" # 0644 by the umask; ci_branch_prepare must tighten it
setsid flock -o -x "$c/locks/$nine.lock" sleep 20 &
holder=$!
sleep 0.3
own_lock_wait() {
    . ci/cache.sh
    CI_LOCK_WAIT=1 ci_branch_prepare "$c" feature/nine
}
refuses NRV-E1225 "a branch's own lock held exclusively" own_lock_wait
is "the branches' lock is released after NRV-E1225" free "$(
    . ci/cache.sh
    CI_LOCK_WAIT=1 ci_branch_prepare "$c" feature/nine >/dev/null 2>&1 || true
    flock -x -n "$c/locks/branches.lock" true && echo free || echo held
)"
kill -- -"$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
is "locks/branches.lock is 0600" 600 "$(stat -c %a "$c/locks/branches.lock")"
is "a branch's lock file is 0600" 600 "$(stat -c %a "$c/locks/$nine.lock")"
is "a branch's lock file is the step's own" "$(id -un)" "$(stat -c %U "$c/locks/$nine.lock")"

# The lock files live in <root>/locks, which a job cannot write (root's, 0700), not in the
# directories `ci` owns: nothing is created in main/ or branches/ any more.
is "no lock file is made in main/ or branches/" "" "$(find "$c/main" "$c/branches" -maxdepth 1 -name '*.lock' -o -maxdepth 1 -name '.lock')"

# The wording of the two waits names holders that can really hold them (not "a job of this branch"
# nor "a step still alive past its timeout": steps hold main's lock shared, and Linux grants a
# shared lock beside shared ones, and a job cannot replace a lock file now).
setsid flock -o -x "$c/locks/main.lock" sleep 20 &
holder=$!
sleep 0.3
mainwait() {
    . ci/cache.sh
    exec 9<"$c/locks/main.lock"
    CI_MAIN_LOCK_WAIT=1 ci_shared_lock
}
out=$(mainwait 2>&1 || true)
kill -- -"$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
grep -q "main's prune.*process on the host" <<<"$out" || { echo "FAIL E1224 wording: $out" >&2; fail=1; }
if grep -q "past its timeout" <<<"$out"; then echo "FAIL E1224 still blames a step past its timeout: $out" >&2; fail=1; fi
setsid flock -o -x "$c/locks/$nine.lock" sleep 20 &
holder=$!
sleep 0.3
out=$(own_lock_wait 2>&1 || true)
kill -- -"$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
grep -q "another step's prune.*process on the host" <<<"$out" || { echo "FAIL E1225 wording: $out" >&2; fail=1; }
if grep -q "never ends" <<<"$out"; then echo "FAIL E1225 still blames a job that never ends: $out" >&2; fail=1; fi

# A link at a lock path, in the lock directory or where the lock files used to be, is never
# followed: the target keeps its mode, owner and content (a root step used to chown and chmod it).
victim="$tmp/victim"
echo precious >"$victim"
chmod 644 "$victim"
if [ "$(id -u)" = 0 ]; then chown nobody "$victim"; fi
want="$(stat -c '%a %u' "$victim") $(cat "$victim")"
sym=$(. ci/cache.sh; ci_branch_key feature/sym)
ln -s "$victim" "$c/branches/.lock" # the old places: never looked at
ln -s "$victim" "$c/branches/$sym.lock"
ln -s "$victim" "$c/main/.lock"
rm -f "$c/locks/branches.lock" "$c/locks/main.lock"
ln -s "$victim" "$c/locks/branches.lock"
ln -s "$victim" "$c/locks/$sym.lock"
ln -s "$victim" "$c/locks/main.lock"
ok "a symlinked branches lock, own lock and main lock are replaced, not followed" bash -c '
    . ci/cache.sh
    ci_branch_prepare "$1" feature/sym
    ci_main_lock_open "$1"' _ "$c"
is "the symlink's target is untouched (mode, owner, content)" "$want" "$(stat -c '%a %u' "$victim") $(cat "$victim")"
regular=yes
for f in branches main "$sym"; do { [ -f "$c/locks/$f.lock" ] && [ ! -L "$c/locks/$f.lock" ]; } || regular=no; done
is "the lock paths are regular files now" yes "$regular"
is "the old places' links are untouched" "yes" "$([ -L "$c/branches/.lock" ] && [ -L "$c/main/.lock" ] && echo yes)"
rm -f "$c/branches/.lock" "$c/branches/$sym.lock" "$c/main/.lock"
# Something that is not a regular file at a lock path is refused (NRV-E1226), not removed.
mkdir "$c/locks/dir.lock"
refuses NRV-E1226 "a lock path that is a directory" bash -c '. ci/cache.sh; ci_lock_file "$1/locks/dir.lock"' _ "$c"
is "a directory at a lock path is left alone" yes "$([ -d "$c/locks/dir.lock" ] && echo yes)"
rmdir "$c/locks/dir.lock"

# NRV-E1226 and E1202: the lock directory itself must be there, a real directory that only this
# user can write.
lk="$tmp/lk"
mkdir -p "$lk/main" "$lk/branches"
refuses NRV-E1202 "no lock directory" ci_cache_check main "$lk"
mkdir -m 0700 "$tmp/lk-real"
ln -s "$tmp/lk-real" "$lk/locks"
refuses NRV-E1226 "a symlinked lock directory" ci_cache_check main "$lk"
rm "$lk/locks"
mkdir "$lk/locks"
chmod 0777 "$lk/locks"
refuses NRV-E1226 "a lock directory others can write" ci_cache_check main "$lk"
chmod 0770 "$lk/locks"
refuses NRV-E1226 "a lock directory the group can write" ci_cache_check main "$lk"
chmod 0700 "$lk/locks"
ok "a lock directory that is ours and 0700" ci_cache_check main "$lk"
if [ "$(id -u)" = 0 ]; then
    chown nobody "$lk/locks"
    refuses NRV-E1226 "a lock directory of another user" ci_cache_check main "$lk"
fi

# NRV-E1227: a lock file that cannot be opened says so, with the reason, and is not reported as a
# wait ("held for N s"). ci_lock_file is stubbed away so that the open itself is what fails (a
# directory cannot be opened for writing); the branches' lock is not kept.
o3="$tmp/openfail"
mkdir -p "$o3/main" "$o3/branches"
mkdir -m 0700 "$o3/locks"
mkdir "$o3/locks/branches.lock"
open_fail() { # open_fail ROOT BRANCH
    . ci/cache.sh
    ci_lock_file() { return 0; }
    ci_branch_prepare "$1" "$2"
}
out=$(open_fail "$o3" feature/o 2>&1 || true)
grep -q "NRV-E1227: could not open the lock file .*branches.lock (Is a directory)" <<<"$out" || { echo "FAIL open failure (fd 7): $out" >&2; fail=1; }
if grep -q "held for\|NRV-W1202\|NRV-E1225" <<<"$out"; then echo "FAIL open failure reported as a wait: $out" >&2; fail=1; fi
rmdir "$o3/locks/branches.lock"
: >"$o3/locks/branches.lock"
okey=$(. ci/cache.sh; ci_branch_key feature/o)
mkdir "$o3/locks/$okey.lock"
out=$(open_fail "$o3" feature/o 2>&1 || true)
grep -q "NRV-E1227: could not open the lock file .*$okey.lock (Is a directory)" <<<"$out" || { echo "FAIL open failure (fd 6): $out" >&2; fail=1; }
if grep -q "held for\|NRV-E1225" <<<"$out"; then echo "FAIL open failure (fd 6) reported as a wait: $out" >&2; fail=1; fi
is "the branches' lock is released after NRV-E1227" free "$(flock -x -n "$o3/locks/branches.lock" true && echo free || echo held)"
refuses NRV-E1227 "an open failure refuses" open_fail "$o3" feature/o

# The step closes its lock descriptors (6 to 9) for the job: bash's exec does not set close-on-exec,
# so a job would inherit them and could take them for good. Both `as_ci` commands do it.
as_ci_lines=$(grep -c '"${as_ci\[@\]}"' ci/woodpecker_step.sh || true)
closing_lines=$(grep -c '"${as_ci\[@\]}".* 6>&- 7>&- 8>&- 9<&-' ci/woodpecker_step.sh || true)
is "woodpecker_step.sh runs two commands as ci" 2 "$as_ci_lines"
is "both close fds 6 to 9 for the job" 2 "$closing_lines"
# Both places that take main's lock use ci_shared_lock (bounded, NRV-E1224), never a bare flock; the
# jepsen lock file is made by ci_lock_file.
is "main's lock is taken by ci_shared_lock in both roles" 2 "$(grep -c 'ci_shared_lock || exit 1' ci/woodpecker_step.sh || true)"
if grep -n 'flock -s 9' ci/woodpecker_step.sh; then echo "FAIL woodpecker_step.sh takes main's lock with a bare flock: use ci_shared_lock" >&2; fail=1; fi
is "the jepsen lock file is made by ci_lock_file" 1 "$(grep -c 'ci_lock_file "$cache/locks/jepsen.lock"' ci/woodpecker_step.sh || true)"
# The pattern itself, through ci_run_timed as the step runs the job: the step holds fd 9 shared
# (as its flock does); the child, with the descriptors closed, cannot lock it (Bad file descriptor),
# and a third opener still cannot take the lock exclusively. Without the closing it can (control).
fdlock="$tmp/fdlock"
: >"$fdlock"
inherit_test() {
    . ci/lib.sh
    exec 9<"$fdlock"
    flock -s 9
    # shellcheck disable=SC2016 # the child's own shell expands it
    ci_run_timed child 20 bash -c 'flock -n -x 9 && echo child-locked'
}
out=$(inherit_test 2>&1) || true
grep -q child-locked <<<"$out" || { echo "FAIL fd control: a child that inherits fd 9 could not lock it: $out" >&2; fail=1; }
closed_test() {
    . ci/lib.sh
    exec 9<"$fdlock"
    flock -s 9
    # shellcheck disable=SC2016
    out=$(ci_run_timed child 20 bash -c 'flock -n -x 9; echo "status=$?"' 6>&- 7>&- 8>&- 9<&- 2>&1)
    grep -q 'Bad file descriptor' <<<"$out" || { echo "no EBADF in: $out"; return 1; }
    if flock -x -n "$fdlock" true; then echo "the step's lock was lost"; return 1; fi
}
ok "a job without fd 9 cannot lock it, and the step's lock holds" closed_test

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
is "host makes the cache directories" yes "$([ -d "$tmp/hostcache/main" ] && [ -d "$tmp/hostcache/branches" ] && [ -d "$tmp/hostcache/jepsen" ] && [ -d "$tmp/hostcache/locks" ] && echo yes)"
is "host makes the lock directory 0700" 700 "$(stat -c %a "$tmp/hostcache/locks")"
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
touch "$c/locks/main.lock"
(
    . ci/cache.sh
    exec 9<"$c/locks/main.lock"
    CI_PRUNE_WAIT=1 ci_main_prune "$c" 99999999
)
is "main pruned when idle (the directories are made again by ci_main_prepare)" no "$([ -e "$c/main/zig-local" ] && echo yes || echo no)"
mkdir -p "$c/main/zig-local"
echo x >"$c/main/zig-local/entry"
setsid flock -o -s "$c/locks/main.lock" sleep 20 &
holder=$!
sleep 0.3
out=$(
    . ci/cache.sh
    exec 9<"$c/locks/main.lock"
    CI_PRUNE_WAIT=1 ci_main_prune "$c" 99999999 2>&1
)
kill -- -"$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
grep -q NRV-W1202 <<<"$out" || { echo "FAIL prune busy: no NRV-W1202 in: $out" >&2; fail=1; }
is "main kept when busy" entry "$(ls "$c/main/zig-local")"
# Space is no longer low once the wait ends: not pruned, and no warning even though the lock is busy.
setsid flock -o -s "$c/locks/main.lock" sleep 20 &
holder=$!
sleep 0.3
out=$(
    . ci/cache.sh
    exec 9<"$c/locks/main.lock"
    CI_PRUNE_WAIT=1 ci_main_prune "$c" 0 2>&1
)
kill -- -"$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
if grep -q NRV-W1202 <<<"$out"; then echo "FAIL prune busy but space free: NRV-W1202 in: $out" >&2; fail=1; fi
is "main kept when space is free again" entry "$(ls "$c/main/zig-local")"
(
    . ci/cache.sh
    exec 9<"$c/locks/main.lock"
    CI_PRUNE_WAIT=1 ci_main_prune "$c" 0 >/dev/null
)
is "main kept when idle and space is free" entry "$(ls "$c/main/zig-local")"

# NRV-E1224: a job that holds main's lock for good does not hold a step up for good.
setsid flock -o -x "$c/locks/main.lock" sleep 20 &
holder=$!
sleep 0.3
lock_wait() {
    . ci/cache.sh
    exec 9<"$c/locks/main.lock"
    CI_MAIN_LOCK_WAIT=1 ci_shared_lock
}
refuses NRV-E1224 "main's lock held exclusively" lock_wait
kill -- -"$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
ok "the shared lock is taken once it is free" lock_wait

# The step script prepares main through ci_main_prepare and makes nothing in a cache a job writes
# as root: no install -d, chown or mkdir on the caches' paths, no fd opened by a bare exec.
grep -q '^    ci_main_prepare .* || exit 1$' ci/woodpecker_step.sh || { echo "FAIL woodpecker_step.sh does not call ci_main_prepare or ignores its failure" >&2; fail=1; }
grep -q '^    ci_branch_prepare .* || exit 1$' ci/woodpecker_step.sh || { echo "FAIL woodpecker_step.sh ignores a failure of ci_branch_prepare" >&2; fail=1; }
if grep -n 'install -d .*\(cache/main\|base\|JEPSEN_OUT\|cache/jepsen/\)\|chown .*\(cache\|base\)\|mkdir .*\(cache\|base\|JEPSEN_OUT\)' ci/woodpecker_step.sh; then
    echo "FAIL woodpecker_step.sh makes or chowns something in a cache a job writes as root: use ci_job_dir" >&2
    fail=1
fi
if grep -n '^ *chown\|install -d\|mkdir\|chmod' ci/cache.sh | grep -v '^[0-9]*: *#' | grep -v 'chown -h\|chmod 600\|ci_as_job\|mkdir -- "\$p"'; then
    echo "FAIL ci/cache.sh makes or chowns something as root outside the lock files" >&2
    fail=1
fi
# Only ci_main_lock_open opens main's lock (fd 9), which is what gives E1226 and E1227; the jepsen
# lock opens read-only with its mode named, so its reason is the real one.
is "only ci_main_lock_open opens fd 9" 1 "$(grep -c 'exec 9<' ci/cache.sh ci/woodpecker_step.sh | awk -F: '{n += $2} END {print n}')"
is "the Docker client is downloaded as the job's user, root only unpacks it" 1 "$(grep -c '^    ci_as_job ci/docker_client.sh .* fetch$' ci/woodpecker_step.sh || true)"
is "the jepsen lock's E1227 probes a read open" 1 "$(grep -c "ci_lock_open_failed \"\$cache/locks/jepsen.lock\" '<'" ci/woodpecker_step.sh || true)"

# The step's own sequence (ci_main_prepare: lock, prune, then the directories): after a prune
# main's directories are made again by the job's user. As root the user is `nobody`.
chmod 711 "$tmp"
if [ "$(id -u)" = 0 ]; then ou=nobody; else ou=$(id -un); fi
chown -R "$ou" "$c/main" 2>/dev/null || true
echo x >"$c/main/zig-local/entry"
(
    . ci/cache.sh
    CI_PRUNE_WAIT=1 ci_main_prepare "$c" "$ou" yes 99999999 >/dev/null
)
is "prepare: main pruned, its directories made again after the prune" "no yes yes yes" "$([ -e "$c/main/zig-local/entry" ] && echo yes || echo no) $([ -d "$c/main/zig" ] && echo yes) $([ -d "$c/main/zig-local" ] && echo yes) $([ -d "$c/main/tools" ] && echo yes)"
is "prepare: locks/main.lock is the step's own, 0600" "$(id -un) 600" "$(stat -c '%U %a' "$c/locks/main.lock")"
is "prepare: zig owned by the job's user after a prune" "$ou" "$(stat -c %U "$c/main/zig")"
is "prepare: zig-local owned by the job's user after a prune" "$ou" "$(stat -c %U "$c/main/zig-local")"
is "prepare: tools owned by the job's user" "$ou" "$(stat -c %U "$c/main/tools")"

# --- A job plants a link where the root step prepares its caches (review 6000214760): nothing
# root does follows it. The job's user is `nobody` as root, else this user. For each path in each
# role, a link to a directory and to a file (both root's, 0700 and 0600, in a directory the job
# cannot write) is planted; the step's prepare code then runs, and must leave the target's owner,
# mode and content alone and the path a plain directory (the link replaced) or refuse it (E1228).
jobuser=$ou
sd="$tmp/sentinel-dir"
sf="$tmp/sentinel-file"
sentinel_state() { echo "$(stat -c '%a %u %g' "$sd") $(stat -c '%a %u %g' "$sf") $(cat "$sf") $(ls -A "$sd" | tr '\n' ,)"; }
reset_sentinels() {
    rm -rf "$sd" "$sf"
    mkdir -m 0700 "$sd"
    echo precious >"$sf"
    chmod 600 "$sf"
}
ci_as() { if [ "$(id -u)" = 0 ]; then setpriv --reuid "$(id -u "$jobuser")" --regid "$(id -g "$jobuser")" --init-groups "$@"; else "$@"; fi; }
reset_sentinels
want_state=$(sentinel_state)
attack_tree() { # attack_tree NAME: a fresh cache root, as the host lays it out, the caches the job's
    local r="$tmp/atk-$1"
    rm -rf "$r"
    mkdir -p "$r/main/zig" "$r/main/zig-local" "$r/main/tools" "$r/branches"
    mkdir -m 0700 "$r/locks"
    chown -R "$jobuser" "$r/main" "$r/branches" 2>/dev/null || true
    echo "$r"
}
branch_key=$(. ci/cache.sh; ci_branch_key feature/atk)
for target in "$sd" "$sf"; do
    for path in "" zig zig-local; do
        r=$(attack_tree b)
        d="$r/branches/$branch_key"
        ci_as mkdir -p "$d/zig" "$d/zig-local"
        if [ -z "$path" ]; then
            ci_as rm -rf "$d"
            ci_as ln -s "$target" "$d"
        else
            ci_as rm -rf "${d:?}/$path"
            ci_as ln -s "$target" "$d/$path"
        fi
        (
            . ci/cache.sh
            CI_JOB_USER=$jobuser ci_branch_prepare "$r" feature/atk >/dev/null 2>&1
        ) || true
        is "branch: link at '${path:-the branch directory}' to $(basename "$target") leaves the target alone" "$want_state" "$(sentinel_state)"
        is "branch: link at '${path:-the branch directory}' replaced by a plain directory the job can write" yes "$([ -d "$d/${path}" ] && [ ! -L "$d/${path}" ] && ci_as test -w "$d/${path}" && echo yes)"
        reset_sentinels
    done
done
for target in "$sd" "$sf"; do
    for path in zig zig-local tools; do
        for low in no yes; do
            r=$(attack_tree m)
            ci_as rm -rf "${r:?}/main/$path"
            ci_as ln -s "$target" "$r/main/$path"
            (
                . ci/cache.sh
                CI_PRUNE_WAIT=1 ci_main_prepare "$r" "$jobuser" "$low" 99999999 >/dev/null 2>&1
            ) || true
            is "main (low=$low): link at $path to $(basename "$target") leaves the target alone" "$want_state" "$(sentinel_state)"
            is "main (low=$low): link at $path replaced by a plain directory the job can write" yes "$([ -d "$r/main/$path" ] && [ ! -L "$r/main/$path" ] && ci_as test -w "$r/main/$path" && echo yes)"
            reset_sentinels
        done
    done
done
# A path that is a file, or a directory the job cannot write, is refused with its code, in both roles.
r=$(attack_tree f)
ci_as rm -rf "$r/main/zig"
: >"$r/main/zig"
refuses NRV-E1228 "main: a file at main/zig" bash -c '. ci/cache.sh; CI_JOB_USER=$2 ci_main_prepare "$1" "$2" no 0' _ "$r" "$jobuser"
is "a file at main/zig is left alone" yes "$([ -f "$r/main/zig" ] && echo yes)"
r=$(attack_tree f2)
chmod a-w "$r/main/zig-local"
chown 0 "$r/main/zig-local" 2>/dev/null || true
[ "$(id -u)" != 0 ] || chmod 755 "$r/main/zig-local"
refuses NRV-E1228 "main: a directory the job cannot write" bash -c '. ci/cache.sh; ci_main_prepare "$1" "$2" no 0' _ "$r" "$jobuser"
r=$(attack_tree f3)
d="$r/branches/$branch_key"
ci_as mkdir -p "$d"
: >"$d/zig-local"
chown "$jobuser" "$d/zig-local" 2>/dev/null || true
refuses NRV-E1228 "branch: a file at zig-local" bash -c '. ci/cache.sh; CI_JOB_USER=$2 ci_branch_prepare "$1" feature/atk' _ "$r" "$jobuser"
# The prune does not take a directory name for a path: a name with a newline in it (a job can make
# one) used to be read as a second name, here `victim`, relative to the step's directory.
r=$(attack_tree n)
mkdir "$tmp/cwd" "$tmp/cwd/victim"
echo keep >"$tmp/cwd/victim/f"
ci_as mkdir -p "$r/branches/$(printf 'b-evil\nvictim')" "$r/branches/b-old-00000001" "$r/branches/b-old-00000002"
touch -d "2 days ago" "$r/branches/b-old-00000001"
touch -d "3 days ago" "$r/branches/b-old-00000002"
(
    cd "$tmp/cwd"
    . "$root/ci/cache.sh"
    CI_JOB_USER=$jobuser CI_BRANCH_CACHES=1 ci_branch_prepare "$r" feature/atk >/dev/null 2>&1
) || true
is "a directory name with a newline does not make the prune remove a path" keep "$(cat "$tmp/cwd/victim/f" 2>/dev/null)"
is "a name that is no branch key is removed, and so are the old caches over the bound" "no no" "$([ -e "$r/branches/$(printf 'b-evil\nvictim')" ] && echo yes || echo no) $([ -e "$r/branches/b-old-00000002" ] && echo yes || echo no)"
# A link named like a branch cache is unlinked by the prune, never followed.
r=$(attack_tree l)
ci_as ln -s "$sd" "$r/branches/b-link-00000003"
ci_as ln -s "$sd" "$r/branches/b-link-00000003.partial.1"
(
    . ci/cache.sh
    CI_JOB_USER=$jobuser ci_branch_prepare "$r" feature/atk >/dev/null 2>&1
) || true
is "a link named like a cache, or like a partial one, is unlinked and the target is left alone" "$want_state no no" "$(sentinel_state) $([ -e "$r/branches/b-link-00000003" ] && echo yes || echo no) $([ -L "$r/branches/b-link-00000003.partial.1" ] && echo yes || echo no)"

# Lock files a prune makes are the step's own, 0600 (they used to be 0644 by root's umask, and a
# job that could list a 0755 lock directory could take them), and a lock directory with any group
# or other bit is refused (NRV-E1226): what Docker makes of a missing mount source is root 0755.
r=$(attack_tree p)
ci_as mkdir -p "$r/branches/b-pruned-00000004" "$r/branches/b-big-00000005"
touch -d "20 days ago" "$r/branches/b-pruned-00000004"
(
    umask 000
    . ci/cache.sh
    CI_JOB_USER=$jobuser ci_branch_prepare "$r" feature/atk >/dev/null 2>&1
    CI_JOB_USER=$jobuser CI_BRANCH_CACHE_MAX_GIB=-1 ci_branch_prepare "$r" feature/atk >/dev/null 2>&1
) || true
is "the lock files a prune makes are 0600" "600 600" "$(stat -c %a "$r/locks/b-pruned-00000004.lock") $(stat -c %a "$r/locks/b-big-00000005.lock")"
is "and the step's own" "$(id -un) $(id -un)" "$(stat -c %U "$r/locks/b-pruned-00000004.lock") $(stat -c %U "$r/locks/b-big-00000005.lock")"
mkdir -p "$tmp/lk755/main" "$tmp/lk755/branches"
mkdir -m 0755 "$tmp/lk755/locks"
refuses NRV-E1226 "a root 0755 lock directory (Docker's own)" ci_cache_check main "$tmp/lk755"
out=$(ci_cache_check main "$tmp/lk755" 2>&1 || true)
grep -q "nerva-woodpecker.sh host" <<<"$out" || { echo "FAIL E1226 for 0755 does not name the fix: $out" >&2; fail=1; }
chmod 0750 "$tmp/lk755/locks"
refuses NRV-E1226 "a lock directory the group can read" ci_cache_check main "$tmp/lk755"

# NRV-E1227 from the read-only opens too (fd 9 here; the reason is the read open's own: a lock
# file that is not there, which the stubbed ci_lock_file leaves out, is "No such file").
o4="$tmp/openfail9"
mkdir -p "$o4/main" "$o4/branches"
mkdir -m 0700 "$o4/locks"
open9_fail() {
    . ci/cache.sh
    ci_lock_file() { return 0; }
    ci_main_lock_open "$1"
}
out=$(open9_fail "$o4" 2>&1 || true)
grep -q "NRV-E1227: could not open the lock file .*main.lock (No such file or directory)" <<<"$out" || { echo "FAIL open failure (fd 9): $out" >&2; fail=1; }
if grep -q "held for\|NRV-E1224" <<<"$out"; then echo "FAIL open failure (fd 9) reported as a wait: $out" >&2; fail=1; fi
refuses NRV-E1227 "fd 9's open failure refuses" open9_fail "$o4"
# The reason is the open's own, in its own mode: a write-only probe would call a read open of a
# directory a failure ("Is a directory"), and a read probe a write open of one a success.
: >"$o4/locks/dir9.lock"
rm "$o4/locks/dir9.lock"
mkdir "$o4/locks/dir9.lock"
out=$(. ci/cache.sh; ci_lock_open_failed "$o4/locks/dir9.lock" '<' 2>&1)
grep -q "(no reason given)" <<<"$out" || { echo "FAIL probe in read mode: $out" >&2; fail=1; }
out=$(. ci/cache.sh; ci_lock_open_failed "$o4/locks/dir9.lock" '>>' 2>&1)
grep -q "(Is a directory)" <<<"$out" || { echo "FAIL probe in write mode: $out" >&2; fail=1; }

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
