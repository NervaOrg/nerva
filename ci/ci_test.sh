#!/usr/bin/env bash
# Table test for the CI scripts' own refusals and cache rules (NRV-E1201 to E1232, NRV-B1201,
# NRV-W1201 to W1203, docs/ERRORS.md; decision O4). Needs flock and jq. Takes a few seconds;
# touches only a scratch directory. Not covered, as they need a Woodpecker step or a daemon:
# NRV-E1203 (the Docker socket is not mounted), NRV-E1209 and E1210 (Jepsen), the io_uring check on
# a real refusing daemon, woodpecker-bootstrap.sh's NRV-E1213 (its preflight wants root on Ubuntu
# 24.04 first). Tests that need two users (root and the job's) or a real read-only bind mount run
# only as root, and the mount ones only where `mount --bind` works; each says so on stderr when it is
# skipped ("note: ..."). Both CIs run this suite as root (ci/job.sh check-scripts): a run that prints
# those notes did not prove the behavioural guards (review 6000930445).
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=${CI_TEST_TMP:-$(mktemp -d)}
ro_mounts=() # bind mounts made by the tests below (root only); unmounted before the scratch directory goes
cleanup() {
    local m
    for m in "${ro_mounts[@]}"; do umount "$m" 2>/dev/null || true; done
    rm -rf "$tmp"
}
trap cleanup EXIT
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

skip_note() { # skip_note WHAT: a block that needs root says so when it does not run
    echo "note: not root: $1 was skipped" >&2
}

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
# The install phase (root's, over a cache a job writes) checks what it unpacks: a pin that matches
# nothing is NRV-E1205 and unpacks nothing; the right pin unpacks, and leaves no temporary behind.
refuses NRV-E1205 "docker client install: archive that is not the pin" env CI_ARCH=x86_64 CI_DOCKER_BIN_DIR="$tmp/dc/bin3" \
    ci/docker_client.sh 9 "$(printf '%064d' 0)" "$tmp/dc/c3" install
is "docker client install: nothing unpacked for a wrong archive" no "$([ -e "$tmp/dc/bin3/docker" ] && echo yes || echo no)"
ok "docker client install: the right archive" env CI_ARCH=x86_64 CI_DOCKER_BIN_DIR="$tmp/dc/bin3" \
    ci/docker_client.sh 9 "$dsha" "$tmp/dc/c3" install
[ -x "$tmp/dc/bin3/docker" ] || { echo "FAIL docker client install: no binary" >&2; fail=1; }
is "docker client install unpacks the copy it checked, not the path (static, a supplement to the swap test)" 1 "$(grep -c 'tar --no-same-owner -xzf "\$work/docker.tgz"' ci/docker_client.sh || true)"
# What is unpacked is what was checked (review 6000627166): a stub for `head` and `cat` (whichever
# reads the archive) swaps the archive's path for another, valid, archive right after it has copied,
# which is where a check by path and an unpack by path would see two files. The unpacked binary
# must be the checked one's.
mkdir -p "$tmp/dc/evil/docker" "$tmp/dc/swap" "$tmp/dc/c5"
printf '#!/bin/sh\necho evil\n' >"$tmp/dc/evil/docker/docker"
chmod +x "$tmp/dc/evil/docker/docker"
tar -czf "$tmp/dc/evil.tgz" -C "$tmp/dc/evil" docker
for n in head cat; do
    printf '#!/bin/bash\n%s "$@"\nrc=$?\nlast="${@: -1}"\nrm -f "$last"\n%s "%s" "$last"\nexit $rc\n' \
        "$(command -v "$n")" "$(command -v cp)" "$tmp/dc/evil.tgz" >"$tmp/dc/swap/$n"
    chmod +x "$tmp/dc/swap/$n"
done
cp "$tmp/dc/docker-9.tgz" "$tmp/dc/c5/docker-9.tgz"
ok "docker client install: the archive is swapped after the copy" env PATH="$tmp/dc/swap:$PATH" CI_ARCH=x86_64 CI_DOCKER_BIN_DIR="$tmp/dc/bin5" \
    ci/docker_client.sh 9 "$dsha" "$tmp/dc/c5" install
is "docker client install unpacks the checked copy, not the swapped path" "$(cat "$tmp/dc/src/docker/docker")" "$(cat "$tmp/dc/bin5/docker" 2>/dev/null)"
is "(the stub did swap the path)" "$(sha256sum <"$tmp/dc/evil.tgz")" "$(sha256sum <"$tmp/dc/c5/docker-9.tgz")"
# NRV-E1230: a directory or a link at the archive's path (a directory made fetch "succeed" by moving
# the download into it, and install then blamed the pin for ever), in each phase; nothing is
# unpacked, and nothing is moved into the directory.
for phase in fetch install all; do
    d="$tmp/dc/plant-$phase"
    rm -rf "$d"
    mkdir -p "$d/docker-9.tgz"
    refuses NRV-E1230 "docker client $phase: a directory at the archive's path" env CI_ARCH=x86_64 CI_DOCKER_CLIENT_URL="file://$tmp/dc/docker-9.tgz" \
        CI_DOCKER_BIN_DIR="$tmp/dc/bin-d-$phase" ci/docker_client.sh 9 "$dsha" "$d" "$phase"
    is "docker client $phase: nothing moved into the directory, nothing unpacked" "" "$(ls -A "$d/docker-9.tgz")$([ -e "$tmp/dc/bin-d-$phase/docker" ] && echo bin)"
    if [ "$phase" = install ]; then
        out=$(env CI_ARCH=x86_64 CI_DOCKER_BIN_DIR="$tmp/dc/bin-m" ci/docker_client.sh 9 "$dsha" "$d" install 2>&1 || true)
        { grep -q "rm -rf" <<<"$out" && ! grep -q "NRV-E1205" <<<"$out"; } || { echo "FAIL E1230 does not tell the host fix, or blames the pin: $out" >&2; fail=1; }
    fi
    rm -rf "$d"
    mkdir -p "$d"
    ln -s "$tmp/dc/docker-9.tgz" "$d/docker-9.tgz" # a link to an archive that matches the pin
    refuses NRV-E1230 "docker client $phase: a link at the archive's path" env CI_ARCH=x86_64 CI_DOCKER_CLIENT_URL="file://$tmp/dc/docker-9.tgz" \
        CI_DOCKER_BIN_DIR="$tmp/dc/bin-l-$phase" ci/docker_client.sh 9 "$dsha" "$d" "$phase"
    is "docker client $phase: the link is left alone, nothing unpacked" "yes no" "$([ -L "$d/docker-9.tgz" ] && echo yes) $([ -e "$tmp/dc/bin-l-$phase/docker" ] && echo yes || echo no)"
done
# The root copy is bounded: a file over the bound is NRV-E1230 (not the pin), and `head` is asked
# for one byte more than the bound (the spy), so an endless source stops there.
mkdir -p "$tmp/dc/spyhead" "$tmp/dc/c6"
printf '#!/bin/bash\necho "$*" >>"%s"\nexec %s "$@"\n' "$tmp/dc/headlog" "$(command -v head)" >"$tmp/dc/spyhead/head"
chmod +x "$tmp/dc/spyhead/head"
cp "$tmp/dc/docker-9.tgz" "$tmp/dc/c6/docker-9.tgz"
refuses NRV-E1230 "docker client install: an archive over the bound" env PATH="$tmp/dc/spyhead:$PATH" CI_DOCKER_MAX_BYTES=10 CI_ARCH=x86_64 \
    CI_DOCKER_BIN_DIR="$tmp/dc/bin6" ci/docker_client.sh 9 "$dsha" "$tmp/dc/c6" install
is "docker client install: an archive over the bound is not unpacked" no "$([ -e "$tmp/dc/bin6/docker" ] && echo yes || echo no)"
grep -q -- "-c 11 " "$tmp/dc/headlog" || { echo "FAIL docker client install: head was not asked for the bound plus one byte: $(cat "$tmp/dc/headlog" 2>&1)" >&2; fail=1; }
out=$(env CI_DOCKER_MAX_BYTES=10 CI_ARCH=x86_64 CI_DOCKER_BIN_DIR="$tmp/dc/bin6" ci/docker_client.sh 9 "$dsha" "$tmp/dc/c6" install 2>&1 || true)
! grep -q "NRV-E1205" <<<"$out" || { echo "FAIL an archive over the bound is blamed on the pin: $out" >&2; fail=1; }
# A read that fails keeps its reason in the message (not "does not match its pin").
mkdir -p "$tmp/dc/failhead"
printf '#!/bin/bash\necho "head: cannot open the archive: Input/output error" >&2\nexit 1\n' >"$tmp/dc/failhead/head"
chmod +x "$tmp/dc/failhead/head"
out=$(env PATH="$tmp/dc/failhead:$PATH" CI_ARCH=x86_64 CI_DOCKER_BIN_DIR="$tmp/dc/bin7" ci/docker_client.sh 9 "$dsha" "$tmp/dc/c6" install 2>&1 || true)
grep -q "NRV-E1230: could not read .*(Input/output error)" <<<"$out" || { echo "FAIL a failed read does not keep its reason: $out" >&2; fail=1; }
# A failed read with no word from head says so, not "()".
mkdir -p "$tmp/dc/silenthead"
printf '#!/bin/bash\nexit 1\n' >"$tmp/dc/silenthead/head"
chmod +x "$tmp/dc/silenthead/head"
out=$(env PATH="$tmp/dc/silenthead:$PATH" CI_ARCH=x86_64 CI_DOCKER_BIN_DIR="$tmp/dc/bin7" ci/docker_client.sh 9 "$dsha" "$tmp/dc/c6" install 2>&1 || true)
grep -q "NRV-E1230: could not read .* (no reason given)" <<<"$out" || { echo "FAIL a failed read with no reason: $out" >&2; fail=1; }
# NRV-E1232: a full disk under the private copy's directory is not the archive's fault: it is not
# NRV-E1230, and it does not say to remove the archive. First with a stub `head` that fails as
# head does on a full disk, then, where a tmpfs can be mounted (root), on a real 64 KiB one.
mkdir -p "$tmp/dc/fullhead"
printf '#!/bin/bash\necho "head: error writing '"'"'standard output'"'"': No space left on device" >&2\nexit 1\n' >"$tmp/dc/fullhead/head"
chmod +x "$tmp/dc/fullhead/head"
out=$(env PATH="$tmp/dc/fullhead:$PATH" CI_ARCH=x86_64 CI_DOCKER_BIN_DIR="$tmp/dc/bin8" ci/docker_client.sh 9 "$dsha" "$tmp/dc/c6" install 2>&1 || true)
{ grep -q "NRV-E1232: .*No space left on device.*TMPDIR" <<<"$out" && ! grep -q "NRV-E1230\|rm -rf" <<<"$out"; } || { echo "FAIL a full disk (stub head): $out" >&2; fail=1; }
mkdir -p "$tmp/dc/tiny"
if [ "$(id -u)" = 0 ] && mount -t tmpfs -o size=64k tmpfs "$tmp/dc/tiny" 2>/dev/null; then
    ro_mounts+=("$tmp/dc/tiny")
    mkdir -p "$tmp/dc/c9"
    head -c 300000 /dev/zero >"$tmp/dc/c9/docker-9.tgz"
    out=$(env TMPDIR="$tmp/dc/tiny" CI_ARCH=x86_64 CI_DOCKER_BIN_DIR="$tmp/dc/bin9" ci/docker_client.sh 9 "$dsha" "$tmp/dc/c9" install 2>&1 || true)
    { grep -q "NRV-E1232: .*No space left on device.*TMPDIR" <<<"$out" && ! grep -q "NRV-E1230\|NRV-E1205\|rm -rf" <<<"$out"; } || { echo "FAIL a full disk (64 KiB tmpfs): $out" >&2; fail=1; }
    is "docker client install: a full disk leaves the archive alone" 300000 "$(stat -c %s "$tmp/dc/c9/docker-9.tgz")"
    umount "$tmp/dc/tiny"
else
    echo "note: no tmpfs here (not root, or mount is denied): the full-disk test of docker_client.sh ran only with a stub head" >&2
fi
# NRV-E1231: CI_DOCKER_MAX_BYTES is a whole number before any arithmetic; an expression in it is
# never evaluated (it would be, as root, by the shell's $(( )) and [ -gt ]).
for bad in abc 0 -5 1+1 01 1.5 "1 2" 1234567890123456 'x[$(touch '"$tmp"'/pwned)]'; do
    refuses NRV-E1231 "docker client: CI_DOCKER_MAX_BYTES='$bad'" env CI_DOCKER_MAX_BYTES="$bad" CI_ARCH=x86_64 \
        CI_DOCKER_BIN_DIR="$tmp/dc/binx" ci/docker_client.sh 9 "$dsha" "$tmp/dc/c6" install
done
is "docker client: an expression in CI_DOCKER_MAX_BYTES is not evaluated" no "$([ -e "$tmp/pwned" ] && echo yes || echo no)"
is "docker client: a bad CI_DOCKER_MAX_BYTES unpacks nothing" no "$([ -e "$tmp/dc/binx/docker" ] && echo yes || echo no)"

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
else
    echo "note: root: a read-only main/ cannot be told from a writable one by mode (only a mount shows it): the unprivileged form of this test was skipped" >&2
fi
# The writability check creates nothing (review 6000451946): a link, or a directory, planted at the
# old probe's name (`.probe.<pid>`, the pid being the checking shell's own) is neither followed nor
# a failure. The plant and the check share one shell, so the name is the one a probe would use.
pr="$tmp/probe"
mkdir -p "$pr/main" "$pr/branches"
mkdir -m 0700 "$pr/locks"
echo precious >"$pr/victim"
bash -c '
    . ci/cache.sh
    ln -s "$1/victim" "$1/main/.probe.$$"
    ln -s "$1/missing" "$1/branches/.probe.$$"
    ci_cache_check main "$1" && ci_cache_writable "$1/branches"
' _ "$pr" 2>"$pr/err" || { echo "FAIL a link planted at .probe.<pid>: the check failed: $(cat "$pr/err")" >&2; fail=1; }
is "a link planted at .probe.<pid> is not followed (victim kept, missing target not made)" "precious no" "$(cat "$pr/victim") $([ -e "$pr/missing" ] && echo yes || echo no)"
rm -f "$pr"/main/.probe.* "$pr"/branches/.probe.*
bash -c '
    . ci/cache.sh
    mkdir "$1/main/.probe.$$" "$1/branches/.probe.$$"
    ci_cache_check main "$1" && ci_cache_writable "$1/branches"
' _ "$pr" 2>"$pr/err" || { echo "FAIL a directory planted at .probe.<pid>: the check failed: $(cat "$pr/err")" >&2; fail=1; }
is "the check made nothing of its own (no stray stderr)" "" "$(cat "$pr/err")"

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
if [ "$(id -u)" = 0 ]; then chown nobody "$victim"; else skip_note "the victim's owner (a link at a lock path is still checked for mode and content)"; fi
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
else
    skip_note "the lock directory of another user (E1226)"
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
if grep -n '^ *chown\|install -d\|mkdir\|chmod' ci/cache.sh | grep -v '^[0-9]*: *#' | grep -v 'chown -h\|chmod 600\|ci_error\|ci_warning\|ci_as_job\|mkdir -- "\$p"\|chmod 0755 -- "\$d"'; then
    echo "FAIL ci/cache.sh makes or chowns something as root outside the lock files" >&2
    fail=1
fi
# Only ci_main_lock_open opens main's lock (fd 9), which is what gives E1226 and E1227; the jepsen
# lock opens read-only with its mode named, so its reason is the real one.
is "only ci_main_lock_open opens fd 9" 1 "$(grep -c 'exec 9<' ci/cache.sh ci/woodpecker_step.sh | awk -F: '{n += $2} END {print n}')"
is "the Docker client is downloaded as the job's user, root only unpacks it" 1 "$(grep -c '^    ci_as_job ci/docker_client.sh .* fetch$' ci/woodpecker_step.sh || true)"
# Both CIs run this suite as root (review 6000930445); static, as a workflow's behaviour is not run here.
is "woodpecker_step.sh runs ci_test.sh itself, as root, for check-scripts (static)" 1 "$(grep -c 'bash ci/ci_test.sh 6>&- 7>&- 8>&- 9<&-' ci/woodpecker_step.sh || true)"
is "ci.yml runs ci_test.sh through sudo (static)" 1 "$(grep -c 'run: sudo env "PATH=\$PATH" bash ci/ci_test.sh' .github/workflows/ci.yml || true)"
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

# A seed made as the job's user (review 6000451946): main's zig/p has a root-owned package, and the
# branch's copy, its directory and its zig/p belong to the job's user, which a root `cp -a`
# (keeps the owner), `mv` or `touch` would not leave. The last three are also pinned statically,
# as an owner cannot tell them apart.
r=$(attack_tree s)
mkdir -p "$r/main/zig/p/pkg"
echo pkg >"$r/main/zig/p/pkg/f"
(
    . ci/cache.sh
    CI_JOB_USER=$jobuser ci_branch_prepare "$r" feature/atk >/dev/null 2>&1
) || true
sd2="$r/branches/$branch_key"
is "seed: the branch directory, zig/p and its package are the job's user's" "$jobuser $jobuser $jobuser $jobuser" "$(stat -c %U "$sd2" "$sd2/zig/p" "$sd2/zig/p/pkg/f" "$sd2/zig-local" | tr '\n' ' ' | sed 's/ $//')"
is "seed: the copy has main's package" pkg "$(cat "$sd2/zig/p/pkg/f" 2>/dev/null)"
is "seed: cp, mv, touch, the partial's cleanup and ci_job_dir's unlink run as the job (static, a supplement to the spy and swap tests below)" 5 "$(grep -c -E 'ci_as_job (cp -a|mv -T "\$partial"|touch "\$dir"|rm -rf "\$partial/zig/p"|rm -f -- "\$p")' ci/cache.sh || true)"
is "ci_cache_writable is root's own test -w and creates nothing (static, a supplement to the mount tests below)" 1 "$(grep -c '^    test -w "\$1"$' ci/cache.sh || true)"

# Which user does what below a branch's directory (review 6000627166; behavioural, so a reformatted
# line cannot hide it): `cp`, `mv`, `touch`, `mkdir`, `mktemp` and `rm` are spies that log the uid
# that ran them and then run the real one. Root may run none of the first five on anything in
# branches/, and no `rm` on a path deeper than a direct child of branches/ (a direct child's last
# component is unlinked and never followed; a deeper path is the job's to swap for a link). The job's
# own calls are in the log too, so a spy that logged nothing is a failure.
spy="$tmp/spy"
mkdir -p "$spy"
chmod 755 "$spy"
: >"$tmp/spy.log"
chmod 666 "$tmp/spy.log"
for n in cp mv touch mkdir mktemp rm; do
    printf '#!/bin/bash\necho "$(id -u) %s $*" >>"$SPY_LOG"\nexec %s "$@"\n' "$n" "$(command -v "$n")" >"$spy/$n"
    chmod 755 "$spy/$n"
done
spy_branch() { # spy_branch ROOT: ci_branch_prepare under the spies
    : >"$tmp/spy.log"
    (
        . ci/cache.sh
        PATH="$spy:$PATH" SPY_LOG="$tmp/spy.log" CI_JOB_USER=$jobuser ci_branch_prepare "$1" feature/atk >/dev/null 2>&1
    ) || true
}
spy_verdict() { # spy_verdict NAME: root's calls in the log, and that the job's were seen
    local jobuid
    jobuid=$(id -u "$jobuser")
    # Only as root is there a root's call to look for: as anyone else, no line of the log starts
    # with 0, and these two would pass whatever the code did.
    if [ "$(id -u)" = 0 ]; then
        is "$1: root ran no cp, mv, touch, mkdir or mktemp in branches/" 0 "$(grep -c -E '^0 (cp|mv|touch|mkdir|mktemp) .*/branches/' "$tmp/spy.log" || true)"
        is "$1: root ran no rm below a branch's directory" 0 "$(grep -c -E '^0 rm .*/branches/[^/ ]+/' "$tmp/spy.log" || true)"
    else
        skip_note "the uid spies' verdict on root ($1)"
    fi
    is "$1: the spies saw the job's calls" yes "$(grep -q -E "^$jobuid (mkdir|mktemp|rm) " "$tmp/spy.log" && echo yes)"
}
# A seed that succeeds, then links planted at the branch's zig and zig-local (a job's doing).
r=$(attack_tree y)
mkdir -p "$r/main/zig/p/pkg"
echo pkg >"$r/main/zig/p/pkg/f"
spy_branch "$r"
spy_verdict "spy, a fresh seed"
d="$r/branches/$branch_key"
ci_as rm -rf "$d/zig" "$d/zig-local"
ci_as ln -s "$sd" "$d/zig"
ci_as ln -s "$sf" "$d/zig-local"
spy_branch "$r"
spy_verdict "spy, links at zig and zig-local"
is "spy: the links were replaced by plain directories" "no no" "$([ -L "$d/zig" ] && echo yes || echo no) $([ -L "$d/zig-local" ] && echo yes || echo no)"
is "spy: the targets of the links are untouched" "$want_state" "$(sentinel_state)"
reset_sentinels
# The failed seed's cleanup cannot be turned on a victim: `cp` is a stub that fails after swapping
# the partial's zig for a link to a root-owned directory (which a job could do between the copy and
# the cleanup); the cleanup, `rm -rf $partial/zig/p`, must run as the job, which cannot delete there.
# Root's version would follow the link and remove victim/p. Needs two users, so only as root.
if [ "$(id -u)" = 0 ]; then
    r=$(attack_tree v)
    mkdir -p "$r/main/zig/p/pkg"
    echo pkg >"$r/main/zig/p/pkg/f"
    victim="$tmp/victim-root"
    rm -rf "$victim"
    mkdir -p "$victim/p"
    echo precious >"$victim/p/f"
    mkdir -p "$tmp/stubcp"
    chmod 755 "$tmp/stubcp"
    cat >"$tmp/stubcp/cp" <<'STUB'
#!/bin/bash
d="${*: -1}"
d="${d%/}"
rm -rf "$d"
ln -s "$VICTIM" "$d"
echo "cp: simulated failure" >&2
exit 1
STUB
    chmod 755 "$tmp/stubcp/cp"
    out=$(
        . ci/cache.sh
        PATH="$tmp/stubcp:$PATH" VICTIM="$victim" CI_JOB_USER=$jobuser ci_branch_prepare "$r" feature/atk 2>&1
    ) || true
    grep -q "seed copy failed" <<<"$out" || { echo "FAIL swapped partial zig: the seed did not fail as the test needs: $out" >&2; fail=1; }
    is "a failed seed's cleanup does not follow a link swapped in for the partial's zig (the victim's p is kept)" precious "$(cat "$victim/p/f" 2>/dev/null)"
else
    skip_note "the failed seed's cleanup under a swapped link"
fi

# The mount question and the ownership question are two (review 6000627166). Both need root and
# another user as the job's.
if [ "$(id -u)" = 0 ]; then
    mk_roots() { # mk_roots DIR: main/ (root's, 0755: what Docker makes of a missing source) with
        # the job's caches in it, and the job's branches/
        rm -rf "$1"
        mkdir -p "$1/main/zig" "$1/main/tools" "$1/branches"
        mkdir -m 0700 "$1/locks"
        chown "$jobuser" "$1/main/zig" "$1/main/tools" "$1/branches"
    }
    chk() { # chk ROLE ROOT
        bash -c '. ci/cache.sh; CI_JOB_USER=$3 ci_cache_check "$1" "$2"' _ "$1" "$2" "$jobuser" 2>&1
    }
    # A main/ mounted read-write that is root's: a branch pipeline must still be refused (E1202): the
    # job's own test of it fails, but main's zig and tools are the job's, so it writes main's caches.
    mk_roots "$tmp/rwroot"
    out=$(chk branch "$tmp/rwroot" 2>&1 || true)
    grep -q "NRV-E1202: main's cache is writable in a pipeline for a branch" <<<"$out" || { echo "FAIL a root-owned read-write main/ in a branch's pipeline: $out" >&2; fail=1; }
    # Main's role: main/ root-owned (Docker's own 0755 root) is mounted read-write and the job cannot
    # write it: NRV-E1229 with the owner and the mode, never E1202, and root does not chown it.
    mk_roots "$tmp/e1229-root-owned"
    out=$(chk main "$tmp/e1229-root-owned" || true)
    grep -q "NRV-E1229: .*main is mounted read-write but the job's user ($jobuser) cannot write it (owner root, uid 0, mode 755).*nerva-woodpecker.sh host.*chmod 0755" <<<"$out" || { echo "FAIL main's role, root-owned main/: $out" >&2; fail=1; }
    ! grep -q "NRV-E1202" <<<"$out" || { echo "FAIL main's role, root-owned main/ is called a mount error: $out" >&2; fail=1; }
    is "main's role, root-owned main/: the host's directory keeps its owner and mode" "0 755" "$(stat -c '%u %a' "$tmp/e1229-root-owned/main")"
    # A job that chmods its own mount root 0555 (NRV-W1203, review 6000930445): the job's uid owns it
    # and only the mode stops it, so the step sets it back to 0755 and warns; every later pipeline
    # would otherwise fail until an operator acted. Both roles; the role's own ci_cache_job_writable
    # call is what is under test, so the branch's mount question is stood in for (as a real read-only
    # main/ and a read-write branches/ would answer it), and a mutant that drops the call (`:`) is
    # caught without a mount.
    chk_stub() { # chk_stub ROLE ROOT: the mount question answered as a branch's mounts would
        bash -c '. ci/cache.sh; r=$2; ci_cache_writable() { [ "$1" != "$r/main" ]; }; CI_JOB_USER=$3 ci_cache_check "$1" "$2"' _ "$1" "$2" "$jobuser" 2>&1
    }
    for role in main branch; do
        if [ "$role" = main ]; then sub=main; else sub=branches; fi
        for mode in 0555 0000 0500; do
            mk_roots "$tmp/w1203-$role-$mode"
            chown "$jobuser" "$tmp/w1203-$role-$mode/$sub"
            ci_as chmod "$mode" "$tmp/w1203-$role-$mode/$sub"
            if [ "$role" = main ]; then out=$(chk main "$tmp/w1203-$role-$mode" && echo RC0); else out=$(chk_stub branch "$tmp/w1203-$role-$mode" && echo RC0); fi || true
            grep -q "NRV-W1203: .*$sub, owned by the job's user ($jobuser), had mode $(printf '%o' $((8#$mode))) and was not writable" <<<"$out" || { echo "FAIL $role's role, $sub/ chmod $mode by the job: no NRV-W1203: $out" >&2; fail=1; }
            grep -q RC0 <<<"$out" || { echo "FAIL $role's role, $sub/ chmod $mode by the job is refused: $out" >&2; fail=1; }
            ! grep -q "NRV-E12" <<<"$out" || { echo "FAIL $role's role, $sub/ chmod $mode by the job gives an error: $out" >&2; fail=1; }
            is "$role's role, $sub/ chmod $mode by the job: set back to the job's, 0755" "$jobuser 755" "$(stat -c '%U %a' "$tmp/w1203-$role-$mode/$sub")"
            ci_as test -w "$tmp/w1203-$role-$mode/$sub" || { echo "FAIL $role's role, $sub/ is still not the job's to write after the repair" >&2; fail=1; }
        done
        # Not the job's: root does not chown or chmod what it was not given. E1229 as before.
        mk_roots "$tmp/foreign-$role"
        chown root "$tmp/foreign-$role/$sub"
        chmod 0555 "$tmp/foreign-$role/$sub"
        if [ "$role" = main ]; then out=$(chk main "$tmp/foreign-$role" || true); else out=$(chk_stub branch "$tmp/foreign-$role" || true); fi
        grep -q "NRV-E1229: .*$sub is mounted read-write but the job's user ($jobuser) cannot write it (owner root, uid 0, mode 555)" <<<"$out" || { echo "FAIL $role's role, root-owned 0555 $sub/: $out" >&2; fail=1; }
        ! grep -q "NRV-W1203" <<<"$out" || { echo "FAIL $role's role, root-owned $sub/ is 'repaired': $out" >&2; fail=1; }
        is "$role's role, root-owned 0555 $sub/: owner and mode untouched" "0 555" "$(stat -c '%u %a' "$tmp/foreign-$role/$sub")"
    done
    # A link at the mount root is never followed: the target keeps its mode.
    mk_roots "$tmp/linkroot"
    mkdir "$tmp/linkroot/target"
    chown "$jobuser" "$tmp/linkroot/target"
    ci_as chmod 0555 "$tmp/linkroot/target"
    rm -rf "$tmp/linkroot/main"
    ln -s target "$tmp/linkroot/main"
    out=$(chk main "$tmp/linkroot" || true)
    grep -q "NRV-E1229" <<<"$out" || { echo "FAIL a link at main/: $out" >&2; fail=1; }
    is "a link at main/: its target keeps its mode" 555 "$(stat -c %a "$tmp/linkroot/target")"
    mk_roots "$tmp/e1229-ok"
    chown "$jobuser" "$tmp/e1229-ok/main"
    ok "main's role, main/ the job's and rw" chk main "$tmp/e1229-ok"
    # With a real read-only mount, which is what a branch's pipeline has.
    ro_bind() { mount --bind "$1" "$1" && ro_mounts+=("$1") && mount -o remount,bind,ro "$1"; }
    mkdir -p "$tmp/mnt-probe"
    can_mount=no
    if ro_bind "$tmp/mnt-probe" 2>/dev/null; then
        ! test -w "$tmp/mnt-probe" || can_mount=probe-writable
        [ "$can_mount" != no ] || can_mount=yes
    fi
    umount "$tmp/mnt-probe" 2>/dev/null || true
    if [ "$can_mount" = yes ]; then
        mk_roots "$tmp/mnt"
        ro_bind "$tmp/mnt/main"
        ok "branch's role: main/ a read-only mount, branches/ the job's" chk branch "$tmp/mnt"
        # A job that chmods its own mount root: not "not mounted" (E1202); repaired with W1203, on a
        # real read-only main/ as well. A root-owned 0555 branches/ is still E1229.
        ci_as chmod 0555 "$tmp/mnt/branches"
        out=$(chk branch "$tmp/mnt" && echo RC0)
        { grep -q "NRV-W1203: .*branches, owned by the job's user ($jobuser), had mode 555" <<<"$out" && grep -q RC0 <<<"$out" && ! grep -q "NRV-E12" <<<"$out"; } || { echo "FAIL branches/ chmod 0555 by the job (read-only main/ mount): $out" >&2; fail=1; }
        is "branches/ chmod 0555 by the job: repaired" "$jobuser 755" "$(stat -c '%U %a' "$tmp/mnt/branches")"
        chown root "$tmp/mnt/branches"
        chmod 0555 "$tmp/mnt/branches"
        out=$(chk branch "$tmp/mnt" || true)
        grep -q "NRV-E1229: .*branches is mounted read-write but the job's user ($jobuser) cannot write it (owner root, uid 0, mode 555)" <<<"$out" || { echo "FAIL root-owned 0555 branches/ (read-only main/ mount): $out" >&2; fail=1; }
        ! grep -q "NRV-E1202" <<<"$out" || { echo "FAIL root-owned 0555 branches/ is called a mount error: $out" >&2; fail=1; }
        umount "$tmp/mnt/main"
        # Main's role with main/ read-only (root writes through a mode, so only a real mount shows it),
        # and a branch's with branches/ read-only: E1202, never E1229.
        mk_roots "$tmp/mnt2"
        chown "$jobuser" "$tmp/mnt2/main"
        ro_bind "$tmp/mnt2/main"
        out=$(chk main "$tmp/mnt2" || true)
        grep -q "NRV-E1202: main's cache is not writable in a pipeline for main" <<<"$out" || { echo "FAIL main's role with a read-only main/: $out" >&2; fail=1; }
        umount "$tmp/mnt2/main"
        mk_roots "$tmp/mnt3"
        ro_bind "$tmp/mnt3/main"
        ro_bind "$tmp/mnt3/branches"
        out=$(chk branch "$tmp/mnt3" || true)
        grep -q "NRV-E1202: .*branches is not writable" <<<"$out" || { echo "FAIL a read-only branches/: $out" >&2; fail=1; }
        ! grep -q "NRV-E1229" <<<"$out" || { echo "FAIL a read-only branches/ is called an ownership error: $out" >&2; fail=1; }
        umount "$tmp/mnt3/branches" "$tmp/mnt3/main"
    else
        echo "note: no read-only bind mount here ($can_mount): the mount tests of ci_cache_check were skipped" >&2
    fi
else
    skip_note "the mount and ownership tests of ci_cache_check (E1202, E1229, W1203)"
fi

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
