#!/usr/bin/env bash
# Table test for the CI scripts' own refusals and cache rules (NRV-E1201 to E1232, NRV-B1201,
# NRV-W1201 to W1206, docs/ERRORS.md; decision O4). Needs flock and jq. Takes about 4 to 5 minutes as root (about 3.5 as another user);
# touches only a scratch directory. Not covered, as they need a Woodpecker step or a daemon:
# NRV-E1203 (the Docker socket is not mounted), NRV-E1209 and E1210 (Jepsen), the io_uring check on
# a real refusing daemon, woodpecker-bootstrap.sh's NRV-E1213 (its preflight wants root on Ubuntu
# 24.04 first). Tests that need two users (root and the job's) or a real read-only bind mount run
# only as root, and the mount ones only where `mount --bind` works; each says so on stderr when it is
# skipped ("note: ..."). Both CIs run this suite as root (ci/job.sh check-scripts): a run that prints
# those notes did not prove the behavioural guards (review 6000930445).
set -eu
# Hermetic (review 6001089776): the scripts read CI_* knobs (CI_BRANCH_PRUNE_ALL, which a step
# exports when the box is low on disk, CI_DOCKER_MAX_BYTES, CI_LOCK_WAIT, CI_BRANCH_CACHES, ...), and
# the step runs this suite as root with the step's environment, pipeline variables included. Every
# exported CI_* variable is dropped; a test that needs one sets it itself, for its own command.
# CI_TEST_TMP (the directory the scratch one is made in; it is never removed) and CI_TEST_NESTED (the guard of the self-test at the end) stay.
for v in $(compgen -e | grep '^CI_' || true); do
    case "$v" in CI_TEST_TMP | CI_TEST_NESTED) ;; *) unset "$v" ;; esac
done
root=$(cd "$(dirname "$0")/.." && pwd)
tmp_base=${CI_TEST_TMP:-${TMPDIR:-/tmp}}
mkdir -p "$tmp_base"
tmp=$(mktemp -d "$tmp_base/ci_test.XXXXXX") # a directory of its own: only what the suite made is removed
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
# NRV-E1232 when the private directory cannot even be made (mktemp -d fails: a TMPDIR that is not
# there, here), with mktemp's own reason, not "no reason given" and not E1230 (review 6001089776).
mkdir -p "$tmp/dc/c10"
cp "$tmp/dc/docker-9.tgz" "$tmp/dc/c10/docker-9.tgz"
out=$(env TMPDIR="$tmp/nonexistent" CI_ARCH=x86_64 CI_DOCKER_BIN_DIR="$tmp/dc/bin10" ci/docker_client.sh 9 "$dsha" "$tmp/dc/c10" install 2>&1 || true)
{ grep -q "NRV-E1232: .*(.*No such file or directory).*TMPDIR" <<<"$out" && ! grep -q "NRV-E1230\|NRV-E1205\|rm -rf" <<<"$out"; } || { echo "FAIL mktemp -d fails: $out" >&2; fail=1; }
is "docker client install: a TMPDIR that is not there leaves the archive alone and unpacks nothing" "yes no" "$([ -f "$tmp/dc/c10/docker-9.tgz" ] && echo yes) $([ -e "$tmp/dc/bin10/docker" ] && echo yes || echo no)"
# NRV-E1232 when the directory is made and the COPY cannot be created in it (no inodes, a quota):
# bash opens the file for head, so without a create of its own first this was reported as a bad
# archive (NRV-E1230). A tmpfs with two inodes has room for mktemp -d and none for the file.
mkdir -p "$tmp/dc/noino"
if [ "$(id -u)" = 0 ] && mount -t tmpfs -o size=1m,nr_inodes=2 tmpfs "$tmp/dc/noino" 2>/dev/null; then
    ro_mounts+=("$tmp/dc/noino")
    out=$(env TMPDIR="$tmp/dc/noino" CI_ARCH=x86_64 CI_DOCKER_BIN_DIR="$tmp/dc/bin11" ci/docker_client.sh 9 "$dsha" "$tmp/dc/c10" install 2>&1 || true)
    { grep -q "NRV-E1232: .*No space left on device.*TMPDIR" <<<"$out" && ! grep -q "NRV-E1230\|NRV-E1205\|rm -rf" <<<"$out"; } || { echo "FAIL no inode for the copy (tmpfs, nr_inodes=2): $out" >&2; fail=1; }
    is "docker client install: no inode for the copy leaves the archive alone" "yes no" "$([ -f "$tmp/dc/c10/docker-9.tgz" ] && echo yes) $([ -e "$tmp/dc/bin11/docker" ] && echo yes || echo no)"
    umount "$tmp/dc/noino"
else
    echo "note: no tmpfs here (not root, or mount is denied): the no-inode test of docker_client.sh was skipped" >&2
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
# As root the job's user is `nobody`, as it is `ci` in a step (a root that acts as its own job is
# NRV-B1202); it must be able to reach the scratch directory.
chmod 711 "$tmp"
if [ "$(id -u)" = 0 ]; then ou=nobody; else ou=$(id -un); fi
export CI_JOB_USER=$ou
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

# NRV-E1214: a branch's cache path that is not a directory, and cannot be reset because another job
# of the branch holds its lock (a job's own file there is otherwise removed and made again, NRV-W1204),
# is refused, not used, and the branches' lock is not kept (a caller that went on would hold every
# branch job up). The message says what is wrong, not that the directory "could not be made".
branch_file() {
    . ci/cache.sh
    ci_branch_prepare "$c" feature/seven
}
seven=$(. ci/cache.sh; ci_branch_key feature/seven)
: >"$c/branches/$seven"
chown "$ou" "$c/branches/$seven" 2>/dev/null || true # the job's own file
: >"$c/locks/$seven.lock"
setsid flock -o -s "$c/locks/$seven.lock" sleep 20 &
holder=$!
sleep 0.3
out=$(branch_file 2>&1) && { echo "FAIL branch cache path is a file: it succeeded, want NRV-E1214" >&2; fail=1; }
grep -q "NRV-E1214: .*is not a directory: remove it" <<<"$out" || { echo "FAIL branch cache path is a file: no 'is not a directory: remove it' in: $out" >&2; fail=1; }
if grep -q 'could not be made' <<<"$out"; then echo "FAIL branch cache path is a file: says 'could not be made': $out" >&2; fail=1; fi
is "the branches' lock is released after NRV-E1214" free "$(
    . ci/cache.sh
    ci_branch_prepare "$c" feature/seven >/dev/null 2>&1 || true
    flock -x -n "$c/locks/branches.lock" true && echo free || echo held
)"
is "a file that cannot be reset is left alone" yes "$([ -f "$c/branches/$seven" ] && echo yes)"
kill -- -"$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
# Nobody holds the lock now: the job's own file is removed and the directory made again, NRV-W1204.
out=$(branch_file 2>&1) || { echo "FAIL a job's file at the branch's path is reset: $out" >&2; fail=1; }
grep -q 'NRV-W1204' <<<"$out" || { echo "FAIL a job's file at the branch's path: no NRV-W1204 in: $out" >&2; fail=1; }
is "the file was replaced by a directory" yes "$([ -d "$c/branches/$seven/zig-local" ] && echo yes)"
rm -rf "${c:?}/branches/$seven"
# The same on the NRV-W1202 path: the branches' lock stays busy, $dir is a file whose lock is held.
eight=$(. ci/cache.sh; ci_branch_key feature/eight)
: >"$c/branches/$eight"
chown "$ou" "$c/branches/$eight" 2>/dev/null || true
: >"$c/locks/$eight.lock"
setsid flock -o -x "$c/locks/branches.lock" sleep 20 &
holder=$!
setsid flock -o -s "$c/locks/$eight.lock" sleep 20 &
holder2=$!
sleep 0.3
branch_file_unlocked() {
    . ci/cache.sh
    CI_LOCK_WAIT=1 ci_branch_prepare "$c" feature/eight
}
out=$(branch_file_unlocked 2>&1) && { echo "FAIL branch cache path is a file, branches' lock busy: it succeeded, want NRV-E1214" >&2; fail=1; }
grep -q "NRV-E1214: .*is not a directory: remove it" <<<"$out" || { echo "FAIL branch cache path is a file, branches' lock busy: no 'is not a directory: remove it' in: $out" >&2; fail=1; }
if grep -q 'could not be made' <<<"$out"; then echo "FAIL branch cache path is a file, branches' lock busy: says 'could not be made': $out" >&2; fail=1; fi
kill -- -"$holder" 2>/dev/null || true
kill -- -"$holder2" 2>/dev/null || true
wait "$holder" "$holder2" 2>/dev/null || true
rm -rf "${c:?}/branches/$eight"
# A job that takes the key's lock exclusively while the reset is done: the re-take of the shared lock
# after it must wait for it and fail NRV-E1225, not be skipped. The reset is wrapped to start such
# a holder right after it has run.
rst=$(. ci/cache.sh; ci_branch_key feature/reset)
: >"$c/branches/$rst"
chown "$ou" "$c/branches/$rst" 2>/dev/null || true
reset_then_hold() {
    . ci/cache.sh
    eval "orig_$(declare -f ci_child_reset)"
    ci_child_reset() {
        orig_ci_child_reset "$@" || return 1
        setsid flock -o -x "$c/locks/$rst.lock" sleep 20 5>&- 6>&- 7>&- &
        echo $! >"$tmp/rst.pid"
        sleep 0.3
    }
    CI_LOCK_WAIT=1 ci_branch_prepare "$c" feature/reset
}
out=$(reset_then_hold 2>&1) && { echo "FAIL a lock taken after the reset: it succeeded, want NRV-E1225" >&2; fail=1; }
grep -q 'NRV-E1225' <<<"$out" || { echo "FAIL a lock taken after the reset: no NRV-E1225 in: $out" >&2; fail=1; }
kill -- -"$(cat "$tmp/rst.pid")" 2>/dev/null || true
wait 2>/dev/null || true
rm -rf "${c:?}/branches/$rst"
# ci_child_reset reports success only if the name is gone: a failing rm (a stub) is rc 1, no NRV-W1204.
mkdir -p "$tmp/badrm" "$c/branches/b-rmfail-00000001"
chown "$ou" "$c/branches/b-rmfail-00000001" 2>/dev/null || true
printf '#!/bin/sh\nexit 1\n' >"$tmp/badrm/rm"
cp "$tmp/badrm/rm" "$tmp/badrm/mv" # the reset moves the tree aside (ci_trash_move), it does not rm it
chmod +x "$tmp/badrm/rm" "$tmp/badrm/mv"
out=$(
    . ci/cache.sh
    PATH="$tmp/badrm:$PATH"
    rc=0
    ci_child_reset "$c/branches/b-rmfail-00000001" "$c/branches" 2>&1 || rc=$?
    echo "rc=$rc"
)
grep -q 'rc=1' <<<"$out" || { echo "FAIL a reset that removed nothing: want rc=1: $out" >&2; fail=1; }
if grep -q 'NRV-W1204' <<<"$out"; then echo "FAIL a reset that removed nothing warns it removed it: $out" >&2; fail=1; fi
rm -rf "${c:?}/branches/b-rmfail-00000001"

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
grep -q "prune or reset of main's caches (a rename).*process on the host" <<<"$out" || { echo "FAIL E1224 wording: $out" >&2; fail=1; }
if grep -q "long rm -rf" <<<"$out"; then echo "FAIL E1224 still blames a long rm -rf under the lock: $out" >&2; fail=1; fi
if grep -q "past its timeout" <<<"$out"; then echo "FAIL E1224 still blames a step past its timeout: $out" >&2; fail=1; fi
setsid flock -o -x "$c/locks/$nine.lock" sleep 20 &
holder=$!
sleep 0.3
out=$(own_lock_wait 2>&1 || true)
kill -- -"$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
grep -q "another step's prune or reset of this branch's cache (a rename.*process on the host" <<<"$out" || { echo "FAIL E1225 wording: $out" >&2; fail=1; }
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
# so a job would inherit them and could take them for good. The install_zig command closes them on
# its own line; the job's (and the root tests') are closed inside ci_step_run_with_tests, whose
# behavioural test below checks it.
as_ci_lines=$(grep -c '"${as_ci\[@\]}"' ci/woodpecker_step.sh || true)
closing_lines=$(grep -c '"${as_ci\[@\]}".* 6>&- 7>&- 8>&- 9<&-' ci/woodpecker_step.sh || true)
is "woodpecker_step.sh runs two commands as ci" 2 "$as_ci_lines"
is "install_zig closes fds 6 to 9 for the job's user (static; the job's own are tested behaviourally)" 1 "$closing_lines"
is "the step runs the root tests and the job through ci_step_job, as arrays (static)" 2 "$(grep -c '^tests_cmd=(bash ci/ci_test.sh)$\|^ci_step_job .* tests_cmd job_cmd || status=\$?$' ci/woodpecker_step.sh || true)"
is "the root tests are bounded by their own limit, not the job's (static; ci_step_job passes it to ci_step_run_with_tests)" "1 1" "$(grep -c '"$((test_minutes \* 60))" tests_cmd job_cmd' ci/woodpecker_step.sh || true) $(grep -c 'ci_step_run_with_tests "\$1" "\$4" "\$job_seconds"' ci/cache.sh || true)"
# Both places that take main's lock use ci_shared_lock (bounded, NRV-E1224), never a bare flock; the
# jepsen lock file is made by ci_lock_file.
is "main's lock is taken by ci_shared_lock in both roles" 2 "$(grep -c 'ci_shared_lock || exit 1' ci/woodpecker_step.sh || true)"
if grep -n 'flock -s 9' ci/woodpecker_step.sh; then echo "FAIL woodpecker_step.sh takes main's lock with a bare flock: use ci_shared_lock" >&2; fail=1; fi
# Review 6003970990: the Jepsen lock (fd 8, which every other run waits on for up to 5400 s) is let go
# before the Jepsen trash is emptied; the sweep of old run directories never moves `tools`; the
# step measures and empties again after its job, in its own tail.
ws=ci/woodpecker_step.sh
unlock8=$(grep -n '^    flock -u 8 2>/dev/null || true$' "$ws" | cut -d: -f1)
empty_j=$(grep -n '^ci_step_finish "\$role" "\$cache" "\${CI_BRANCH_DIR:-}" "\$job"$' "$ws" | cut -d: -f1)
is "jepsen's lock (fd 8) is let go before its trash is emptied, by the tail (static)" yes "$([ -n "$unlock8" ] && [ -n "$empty_j" ] && [ "$unlock8" -lt "$empty_j" ] && echo yes)"
lock8_l=$(grep -n 'flock -x -w "\${CI_JEPSEN_WAIT:-5400}" 8' "$ws" | cut -d: -f1)
pre_j=$(grep -n '^    ci_trash_empty "\$cache/jepsen" #' "$ws" | cut -d: -f1)
is "jepsen's old trash is emptied before the step takes the Jepsen lock others wait on (static)" yes "$([ -n "$lock8_l" ] && [ -n "$pre_j" ] && [ "$pre_j" -lt "$lock8_l" ] && echo yes)"
run_l=$(grep -n '^ci_step_job ' "$ws" | cut -d: -f1)
finish_l=$(grep -n '^ci_step_finish "\$role" "\$cache" "\${CI_BRANCH_DIR:-}" "\$job"$' "$ws" | cut -d: -f1)
is "the step measures and empties its trash after the job, in its tail (static)" yes "$([ -n "$run_l" ] && [ -n "$finish_l" ] && [ "$run_l" -lt "$finish_l" ] && echo yes)"
is "the old run directories are swept by ci_jepsen_sweep, with no age test of its own (static)" "1 0" "$(grep -c '^    ci_jepsen_sweep "\$cache/jepsen"$' "$ws" || true) $(grep -c -e '-mtime' "$ws" || true)"
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
# A trash a crashed reset-cache left in locks/ is removed by host.
mkdir -p "$tmp/hostcache/locks/trash/zig.crashed/deep"
: >"$tmp/hostcache/locks/trash/zig.crashed/deep/f"
out=$(nw FAKE_DOCKER=ok -- host 2>&1) || { echo "FAIL host with a leftover trash: $out" >&2; fail=1; }
is "host removes the trash a crashed reset-cache left" no "$([ -e "$tmp/hostcache/locks/trash" ] && echo yes || echo no)"
# A mount root's own .trash (ci_trash_move's): a root-owned one is emptied and stays; a link or a
# job-owned one (an earlier layout) is removed whole, never followed.
if [ "$(id -u)" = 0 ]; then # "root-owned" means uid 0: a non-root user owns everything it makes
    mkdir -p "$tmp/hostcache/main/.trash/box/deep"
    chmod 0700 "$tmp/hostcache/main/.trash"
    : >"$tmp/hostcache/main/.trash/box/deep/f"
    mkdir -p "$tmp/hostsentinel"
    : >"$tmp/hostsentinel/keep"
    ln -s "$tmp/hostsentinel" "$tmp/hostcache/branches/.trash"
    mkdir -p "$tmp/hostcache/jepsen/.trash/box"
    chown "nobody" "$tmp/hostcache/jepsen/.trash" "$tmp/hostcache/jepsen/.trash/box"
    out=$(nw FAKE_DOCKER=ok -- host 2>&1) || { echo "FAIL host with leftover .trash directories: $out" >&2; fail=1; }
    is "host empties a root-owned .trash and keeps it; a link or a job-owned one is removed; the link's target is left alone" "yes yes no yes" "$([ -d "$tmp/hostcache/main/.trash" ] && echo yes) $([ -z "$(ls -A "$tmp/hostcache/main/.trash")" ] && echo yes) $([ -e "$tmp/hostcache/branches/.trash" ] || [ -e "$tmp/hostcache/jepsen/.trash" ] && echo yes || echo no) $([ -e "$tmp/hostsentinel/keep" ] && echo yes)"
    rm -rf "$tmp/hostcache/main/.trash" "$tmp/hostcache/branches/.trash" "$tmp/hostcache/jepsen/.trash"
    # A trash a step refuses for its mode or ACL (NRV-E1236: an operator's mkdir, a restore from a
    # backup) is set right, not just emptied; one that is not a directory is removed.
    mkdir -m 0755 "$tmp/hostcache/main/.trash"
    mkdir -p "$tmp/hostcache/main/.trash/box"
    if command -v setfacl >/dev/null && setfacl -m "u:nobody:rwx" "$tmp/hostcache/main/.trash" 2>/dev/null; then
        :
    else
        echo "note: this file system takes no ACLs: the host trash ACL repair was skipped" >&2
    fi
    : >"$tmp/hostcache/branches/.trash"
    mkfifo "$tmp/hostcache/jepsen/.trash"
    out=$(nw FAKE_DOCKER=ok -- host 2>&1) || { echo "FAIL host with a trash of the wrong mode, a file and a FIFO: $out" >&2; fail=1; }
    is "host sets a root-owned .trash to 0700, no ACL, empty; removes a file and a FIFO (E1236 would refuse each)" "700 no yes no no" "$(stat -c %a "$tmp/hostcache/main/.trash") $(ls -ld "$tmp/hostcache/main/.trash" | cut -c1-11 | grep -q + && echo yes || echo no) $([ -z "$(ls -A "$tmp/hostcache/main/.trash")" ] && echo yes) $([ -e "$tmp/hostcache/branches/.trash" ] && echo yes || echo no) $([ -e "$tmp/hostcache/jepsen/.trash" ] && echo yes || echo no)"
    # ... and what then passes a step's own check of the trash (ci_trash_ready).
    out=$( (. ci/cache.sh; ci_trash_ready "$tmp/hostcache/main") 2>&1) || { echo "FAIL a trash that host repaired is still refused: $out" >&2; fail=1; }
    rm -rf "$tmp/hostcache/main/.trash" "$tmp/hostcache/branches/.trash" "$tmp/hostcache/jepsen/.trash"
    # A day-old temporary size record (a step that was killed) is removed; a fresh one stays.
    : >"$tmp/hostcache/locks/b-x-00000001.size.AbCdEf"
    : >"$tmp/hostcache/locks/b-y-00000002.size.GhIjKl"
    touch -d "3 days ago" "$tmp/hostcache/locks/b-x-00000001.size.AbCdEf"
    out=$(nw FAKE_DOCKER=ok -- host 2>&1) || { echo "FAIL host with temporary size records: $out" >&2; fail=1; }
    is "host removes a day-old temporary size record and keeps a fresh one" "no yes" "$([ -e "$tmp/hostcache/locks/b-x-00000001.size.AbCdEf" ] && echo yes || echo no) $([ -e "$tmp/hostcache/locks/b-y-00000002.size.GhIjKl" ] && echo yes || echo no)"
    rm -f "$tmp/hostcache/locks/b-y-00000002.size.GhIjKl"
else
    skip_note "the host .trash cleanup (it tells a root-owned trash from a job-owned one)"
fi
is "host makes the mount roots 0755 and makes none of their directories" "755 755 755 yes" "$(stat -c %a "$tmp/hostcache/main") $(stat -c %a "$tmp/hostcache/branches") $(stat -c %a "$tmp/hostcache/jepsen") $([ -z "$(find "$tmp/hostcache/main" "$tmp/hostcache/branches" "$tmp/hostcache/jepsen" -mindepth 1)" ] && echo yes)"
# A box that ran the earlier layout: the roots the job's, one with an ACL: run again, they are root's 0755 with no ACL.
if [ "$(id -u)" = 0 ] && command -v setfacl >/dev/null && id nobody >/dev/null 2>&1; then
    chown nobody "$tmp/hostcache/main" "$tmp/hostcache/branches"
    chmod 0555 "$tmp/hostcache/main"
    setfacl -d -m u::---,g::---,o::--- "$tmp/hostcache/branches" 2>/dev/null || true
    out=$(nw FAKE_DOCKER=ok -- host 2>&1) || { echo "FAIL host on job-owned roots: $out" >&2; fail=1; }
    # (The install stub above drops -o and -g, so the owner is checked statically below.)
    is "host sets job-owned mount roots to 0755 and removes their ACL" "755 no" "$(stat -c %a "$tmp/hostcache/main") $(m=$(ls -ld "$tmp/hostcache/branches"); [[ "${m%% *}" == *+ ]] && echo yes || echo no)"
fi
is "host installs the mount roots root-owned (static)" 1 "$(grep -c 'install -d -m 0755 -o 0 -g 0 "\$root" "\$root/main" "\$root/branches" "\$root/jepsen"' ops/ci/nerva-woodpecker.sh || true)"
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
) >/dev/null
(. ci/cache.sh; ci_trash_empty "$c/main") # the next prunes measure a trash that is empty (a draining one is (e2))
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
# as root, itself: no install -d, chown or mkdir on the caches' paths, no fd opened by a bare exec.
# The root operations are in ci/cache.sh, listed at its top (ci_mount_root, ci_child_make,
# ci_child_reset and the branch's partial directory), where the spies below watch them run.
grep -q '^    ci_main_prepare .* || exit 1$' ci/woodpecker_step.sh || { echo "FAIL woodpecker_step.sh does not call ci_main_prepare or ignores its failure" >&2; fail=1; }
grep -q '^    ci_branch_prepare .* || exit 1$' ci/woodpecker_step.sh || { echo "FAIL woodpecker_step.sh ignores a failure of ci_branch_prepare" >&2; fail=1; }
if grep -n 'install -d .*\(cache/main\|base\|JEPSEN_OUT\|cache/jepsen\)\|chown .*\(cache\|base\)\|mkdir .*\(cache\|base\|JEPSEN_OUT\)' ci/woodpecker_step.sh; then
    echo "FAIL woodpecker_step.sh makes or chowns something in a cache a job writes as root: use ci_mount_root, ci_child_ensure or ci_child_make" >&2
    fail=1
fi
if grep -n -E '(^|[ (;&|])(chown|install -d|mkdir|chmod|mktemp|mv|touch|cp|ln) ' ci/cache.sh | grep -v '^[0-9]*: *#' |
    grep -v -E 'ci_error|ci_warning|ci_as_job|command -v|chown -h "|chmod 0755 -- "\$d"|chmod 600|mkdir -m 0755 -- "\$p"|mktemp -d "\$b/\$key.partial|mv -T "\$partial" "\$dir"|mktemp -d "\$t/t\.|mkdir -m 0700 -- "\$t"|mv -T "\$\{nocopy\[@\]\}" -- "\$p" "\$box/x"|mv --help|mktemp "\$f\.XXXXXX"|mv -f -- "\$new" "\$f"|touch -- "\$f"|-exec chmod u\+r'; then
    echo "FAIL ci/cache.sh makes, chowns, chmods or moves something as root outside the operations listed at its top" >&2
    fail=1
fi
is "ci_mount_root's chmod and chown are on the mount root, nothing else (static)" 1 "$(grep -c 'chmod 0755 -- "\$d"' ci/cache.sh || true)"
is "the jepsen root is made by ci_mount_root, its children by ci_child_ensure and ci_child_make (static)" "1 1 1" "$(grep -c 'ci_mount_root "\$cache/jepsen"' ci/woodpecker_step.sh) $(grep -c 'ci_child_ensure "\$cache/jepsen/tools"' ci/woodpecker_step.sh) $(grep -c 'ci_child_make "\$JEPSEN_OUT"' ci/woodpecker_step.sh)"
is "the acl package is installed by the step (static)" 1 "$(grep -c 'util-linux acl >/dev/null' ci/woodpecker_step.sh || true)"
# Only ci_main_lock_open opens main's lock (fd 9), which is what gives E1226 and E1227; the jepsen
# lock opens read-only with its mode named, so its reason is the real one.
is "only ci_main_lock_open opens fd 9" 1 "$(grep -c 'exec 9<' ci/cache.sh ci/woodpecker_step.sh | awk -F: '{n += $2} END {print n}')"
is "the Docker client is downloaded as the job's user, root only unpacks it" 1 "$(grep -c '^    ci_as_job ci/docker_client.sh .* fetch$' ci/woodpecker_step.sh || true)"
# Both CIs run this suite as root (review 6000930445); static, as a workflow's behaviour is not run here.
is "ci.yml runs ci_test.sh through sudo (static)" 1 "$(grep -c 'run: sudo env "PATH=\$PATH" bash ci/ci_test.sh' .github/workflows/ci.yml || true)"
is "the jepsen lock's E1227 probes a read open" 1 "$(grep -c "ci_lock_open_failed \"\$cache/locks/jepsen.lock\" '<'" ci/woodpecker_step.sh || true)"

# The step's own sequence (ci_main_prepare: lock, prune, then the directories): after a prune
# main's directories are made again, by root, and handed to the job's user. As root the user is `nobody`.
chown "$ou" "$c/main/zig" "$c/main/zig-local" "$c/main/tools" 2>/dev/null || true
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
is "prepare: main/ itself is the step's, not the job's" "$(id -un)" "$(stat -c %U "$c/main")"

# --- What a job leaves where the root step prepares its caches (review 6000214760): nothing root
# does follows a link. The job's user is `nobody` as root, else this user. The mount roots are
# root's (rule 1 of ci/cache.sh): a job cannot make or swap a name directly in one, so what is left
# there is what an earlier layout or an earlier root-made child became (planted below by root and
# handed to the job's uid, which is how it would have been the job's), and what the job does below
# it. For each path in each role, a link to a directory and to a file (both root's, 0700 and 0600,
# in a directory the job cannot write) is planted; the step's prepare code then runs, and must leave
# the target's owner, mode and content alone and the path a plain directory (the link replaced).
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
plant() { # plant KIND PATH [TARGET]: root makes it, directly in a mount root, and hands it to the job's uid
    case "$1" in
        dir) mkdir "$2" ;;
        file) : >"$2" ;;
        fifo) mkfifo "$2" ;;
        link) ln -s "$3" "$2" ;;
    esac
    chown -h "$jobuser" "$2" 2>/dev/null || true
}
mk_branch() { # mk_branch DIR: a branch's directory as the step leaves it, zig and zig-local the job's own
    plant dir "$1"
    ci_as mkdir "$1/zig" "$1/zig-local"
}
reset_sentinels
want_state=$(sentinel_state)
attack_tree() { # attack_tree NAME: a fresh cache root, as the host lays it out: roots root's, 0755; main's children the job's
    local r="$tmp/atk-$1"
    rm -rf "$r"
    mkdir -p "$r/main/zig" "$r/main/zig-local" "$r/main/tools" "$r/branches"
    mkdir -m 0700 "$r/locks"
    chmod 0755 "$r/main" "$r/branches" # whatever the umask: reset-cache refuses a root others can write
    chown "$jobuser" "$r/main/zig" "$r/main/zig-local" "$r/main/tools" 2>/dev/null || true
    echo "$r"
}
usable() { ci_as sh -c 'test -w "$1" && test -x "$1"' _ "$1"; }
branch_key=$(. ci/cache.sh; ci_branch_key feature/atk)
for target in "$sd" "$sf"; do
    for path in "" zig zig-local; do
        r=$(attack_tree b)
        d="$r/branches/$branch_key"
        if [ -z "$path" ]; then
            plant link "$d" "$target"
        else
            mk_branch "$d"
            ci_as rm -rf "${d:?}/$path"
            ci_as ln -s "$target" "$d/$path"
        fi
        (
            . ci/cache.sh
            CI_JOB_USER=$jobuser ci_branch_prepare "$r" feature/atk >/dev/null 2>&1
        ) || true
        is "branch: link at '${path:-the branch directory}' to $(basename "$target") leaves the target alone" "$want_state" "$(sentinel_state)"
        is "branch: link at '${path:-the branch directory}' replaced by a plain directory the job can write" yes "$([ -d "$d/${path}" ] && [ ! -L "$d/${path}" ] && usable "$d/${path}" && echo yes)"
        reset_sentinels
    done
done
for target in "$sd" "$sf"; do
    for path in zig zig-local tools; do
        for low in no yes; do
            r=$(attack_tree m)
            rm -rf "${r:?}/main/$path"
            plant link "$r/main/$path" "$target"
            (
                . ci/cache.sh
                CI_PRUNE_WAIT=1 ci_main_prepare "$r" "$jobuser" "$low" 99999999 >/dev/null 2>&1
            ) || true
            is "main (low=$low): link at $path to $(basename "$target") leaves the target alone" "$want_state" "$(sentinel_state)"
            is "main (low=$low): link at $path replaced by a plain directory the job can write" yes "$([ -d "$r/main/$path" ] && [ ! -L "$r/main/$path" ] && usable "$r/main/$path" && echo yes)"
            reset_sentinels
        done
    done
done
# A name that is not a directory, the job's: a file, a FIFO. It is removed by root and made again
# (NRV-W1204), both roles; a directory the job could use afterwards, and one it makes in it comes out usable.
for kind in file fifo; do
    r=$(attack_tree "k-$kind")
    rm -rf "${r:?}/main/zig"
    plant "$kind" "$r/main/zig"
    out=$(bash -c '. ci/cache.sh; CI_PRUNE_WAIT=1 ci_main_prepare "$1" "$2" no 0 2>&1 && echo RC0' _ "$r" "$jobuser" || true)
    grep -q "NRV-W1204: $r/main/zig, .*was: $([ "$kind" = file ] && echo 'regular empty file' || echo fifo)" <<<"$out" || { echo "FAIL main: a $kind at main/zig: no NRV-W1204 in: $out" >&2; fail=1; }
    grep -q RC0 <<<"$out" || { echo "FAIL main: a $kind at main/zig is refused: $out" >&2; fail=1; }
    is "main: a $kind at main/zig: made again, a directory the job can use and make a usable directory in" "yes yes" "$([ -d "$r/main/zig" ] && usable "$r/main/zig" && echo yes) $(ci_as mkdir "$r/main/zig/new" && usable "$r/main/zig/new" && echo yes)"
    r=$(attack_tree "kb-$kind")
    plant "$kind" "$r/branches/$branch_key"
    out=$( (. ci/cache.sh; CI_JOB_USER=$jobuser ci_branch_prepare "$r" feature/atk 2>&1 && echo RC0) || true)
    grep -q "NRV-W1204: $r/branches/$branch_key, " <<<"$out" || { echo "FAIL branch: a $kind at the branch directory: no NRV-W1204 in: $out" >&2; fail=1; }
    grep -q RC0 <<<"$out" || { echo "FAIL branch: a $kind at the branch directory is refused: $out" >&2; fail=1; }
    is "branch: a $kind at the branch directory: made again, a directory the job can use and make a usable directory in" "yes yes" "$([ -d "$r/branches/$branch_key/zig" ] && usable "$r/branches/$branch_key" && echo yes) $(ci_as mkdir "$r/branches/$branch_key/zig/new" && usable "$r/branches/$branch_key/zig/new" && echo yes)"
done
# A path that is not the job's is refused with its code, never touched (root only: a second user).
if [ "$(id -u)" = 0 ]; then
    r=$(attack_tree f)
    rm -rf "${r:?}/main/zig"
    : >"$r/main/zig" # root's
    refuses NRV-E1228 "main: a root-owned file at main/zig" bash -c '. ci/cache.sh; CI_JOB_USER=$2 ci_main_prepare "$1" "$2" no 0' _ "$r" "$jobuser"
    is "a root-owned file at main/zig is left alone" yes "$([ -f "$r/main/zig" ] && [ "$(stat -c %u "$r/main/zig")" = 0 ] && echo yes)"
    r=$(attack_tree f2)
    chown 0 "$r/main/zig-local" # root's directory, 0755: the job cannot write it
    refuses NRV-E1228 "main: a directory the job cannot write, root's" bash -c '. ci/cache.sh; ci_main_prepare "$1" "$2" no 0' _ "$r" "$jobuser"
    r=$(attack_tree f3)
    d="$r/branches/$branch_key"
    : >"$d" # root's file
    refuses NRV-E1214 "branch: a root-owned file at the branch directory (not the job's: removing it is not root's)" bash -c '. ci/cache.sh; CI_JOB_USER=$2 ci_branch_prepare "$1" feature/atk' _ "$r" "$jobuser"
    is "a root-owned file at the branch directory is left alone" yes "$([ -f "$d" ] && echo yes)"
else
    skip_note "the NRV-E1228 for a path another user owns"
fi
# A file at zig-local, deeper than the direct child, is the job's own to replace (NRV-W1204 as the job).
r=$(attack_tree f4)
d="$r/branches/$branch_key"
mk_branch "$d"
ci_as rm -rf "${d:?}/zig-local"
ci_as touch "$d/zig-local"
out=$( (. ci/cache.sh; CI_JOB_USER=$jobuser ci_branch_prepare "$r" feature/atk 2>&1 && echo RC0) || true)
{ grep -q 'NRV-W1204' <<<"$out" && grep -q RC0 <<<"$out"; } || { echo "FAIL branch: a file at zig-local: want NRV-W1204 and success: $out" >&2; fail=1; }
is "branch: a file at zig-local is replaced by a directory the job can use" yes "$([ -d "$d/zig-local" ] && usable "$d/zig-local" && echo yes)"
# The prune does not take a directory name for a path: a name with a newline in it (a job can make
# one) used to be read as a second name, here `victim`, relative to the step's directory.
r=$(attack_tree n)
mkdir "$tmp/cwd" "$tmp/cwd/victim"
echo keep >"$tmp/cwd/victim/f"
plant dir "$r/branches/$(printf 'b-evil\nvictim')"
plant dir "$r/branches/b-old-00000001"
plant dir "$r/branches/b-old-00000002"
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
plant link "$r/branches/b-link-00000003" "$sd"
plant link "$r/branches/b-link-00000003.partial.1" "$sd"
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
is "seed: cp, touch, the partial's cleanup and ci_job_dir's removal run as the job (static, a supplement to the spy and swap tests below)" 4 "$(grep -c -E 'ci_as_job (cp -a|touch "\$dir"|rm -rf "\$partial/zig/p"|rm -rf --one-file-system -- "\$p")' ci/cache.sh || true)"
is "ci_cache_writable is root's own test -w and creates nothing (static, a supplement to the mount tests below)" 1 "$(grep -c '^    test -w "\$1"$' ci/cache.sh || true)"
# Which user does what in a branch's cache (review 6000627166; behavioural, so a reformatted line
# cannot hide it): `cp`, `mv`, `touch`, `mkdir`, `mktemp`, `rm` and `chown` are spies that log the uid
# that ran them and then run the real one. Root may run no `cp` or `touch` on anything in branches/,
# and `mkdir`, `mktemp`, `mv`, `rm` and `chown` only on a DIRECT child of branches/ (rule 1 and 2 of
# ci/cache.sh: root's own directory, nothing a job can swap for a link; a direct child's last
# component is unlinked and never followed), never on a path below one. The job's own calls are in
# the log too, so a spy that logged nothing is a failure.
spy="$tmp/spy"
mkdir -p "$spy"
chmod 755 "$spy"
: >"$tmp/spy.log"
chmod 666 "$tmp/spy.log"
for n in cp mv touch mkdir mktemp rm chown; do
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
        is "$1: root ran no cp or touch in branches/" 0 "$(grep -c -E '^0 (cp|touch) .*/branches/' "$tmp/spy.log" || true)"
        # Root makes, hands over, renames and removes the DIRECT children of branches/ (rule 1 and 2
        # of ci/cache.sh), and nothing deeper: no path of any of its calls goes below one.
        is "$1: no call of root's names a path below a branch's directory" 0 "$(grep -c -E '^0 (mkdir|mktemp|mv|rm|chown) .*/branches/[^/ ]+/' "$tmp/spy.log" || true)"
    else
        skip_note "the uid spies' verdict on root ($1)"
    fi
    is "$1: the spies saw the job's calls" yes "$(grep -q -E "^$jobuid (mkdir|cp) " "$tmp/spy.log" && echo yes)"
}
# A seed that succeeds, then links planted at the branch's zig and zig-local (a job's doing).
r=$(attack_tree y)
mkdir -p "$r/main/zig/p/pkg"
echo pkg >"$r/main/zig/p/pkg/f"
spy_branch "$r"
spy_verdict "spy, a fresh seed"
if [ "$(id -u)" = 0 ]; then
    is "spy, a fresh seed: root did make the partial directory, hand it over and rename it (the spy is live)" "yes yes yes" "$(grep -q -E '^0 mktemp .*/branches/' "$tmp/spy.log" && echo yes) $(grep -q -E '^0 chown .*/branches/' "$tmp/spy.log" && echo yes) $(grep -q -E '^0 mv .*/branches/' "$tmp/spy.log" && echo yes)"
fi
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

has_acl() { local m; m=$(ls -ldn -- "$1" 2>/dev/null) || return 1; [[ "${m%% *}" == *+ ]]; } # as ci_has_acl of ci/cache.sh
# The mount roots (rule 1 of ci/cache.sh): root's, mode 0755, no ACL, never the job's. The mount
# question and the ownership question are two (review 6000627166). Both need root and another user
# as the job's.
acl_ok=no # whether this file system keeps ACLs (and setfacl is there): the ACL tests say so when skipped
if command -v setfacl >/dev/null; then
    mkdir "$tmp/aclprobe"
    if setfacl -d -m o::--- "$tmp/aclprobe" 2>/dev/null && has_acl "$tmp/aclprobe"; then acl_ok=yes; fi
fi
if [ "$(id -u)" = 0 ]; then
    third=
    for u in daemon bin sys; do
        if id "$u" >/dev/null 2>&1 && [ "$u" != "$jobuser" ]; then third=$u; break; fi
    done
    mk_roots() { # mk_roots DIR: the roots root's, 0755 (what `host` makes, and Docker of a missing source), main's caches the job's
        rm -rf "$1"
        mkdir -p "$1/main/zig" "$1/main/tools" "$1/branches"
        mkdir -m 0700 "$1/locks"
        chown "$jobuser" "$1/main/zig" "$1/main/tools"
    }
    chk() { # chk ROLE ROOT
        bash -c '. ci/cache.sh; CI_JOB_USER=$3 ci_cache_check "$1" "$2"' _ "$1" "$2" "$jobuser" 2>&1
    }
    # A main/ mounted read-write that is root's: a branch pipeline must still be refused (E1202): root
    # writes it whatever its mode, and the job's own caches in it are writable.
    mk_roots "$tmp/rwroot"
    out=$(chk branch "$tmp/rwroot" 2>&1 || true)
    grep -q "NRV-E1202: main's cache is writable in a pipeline for a branch" <<<"$out" || { echo "FAIL a root-owned read-write main/ in a branch's pipeline: $out" >&2; fail=1; }
    # Main's role: main/ root-owned 0755 with no ACL (what `host` makes) is the right state: no message.
    mk_roots "$tmp/e1229-root-owned"
    out=$(chk main "$tmp/e1229-root-owned" && echo RC0) || true
    is "main's role, root-owned main/: accepted, nothing said" "RC0" "$out"
    is "main's role, root-owned main/: the host's directory keeps its owner and mode" "0 755" "$(stat -c '%u %a' "$tmp/e1229-root-owned/main")"
    # A job cannot change a root: not its mode, not its ACL, not its owner.
    is "a job cannot chmod, chown or set an ACL on a mount root (root-owned 0755)" "no no no" "$(ci_as chmod 0777 "$tmp/e1229-root-owned/main" 2>/dev/null && echo yes || echo no) $(ci_as chown "$jobuser" "$tmp/e1229-root-owned/main" 2>/dev/null && echo yes || echo no) $(ci_as setfacl -d -m o::--- "$tmp/e1229-root-owned/main" 2>/dev/null && echo yes || echo no)"
    is "a job cannot make or remove a name directly in a mount root" "no no" "$(ci_as mkdir "$tmp/e1229-root-owned/main/x" 2>/dev/null && echo yes || echo no) $(ci_as rm -rf "$tmp/e1229-root-owned/main/tools" 2>/dev/null; [ -d "$tmp/e1229-root-owned/main/tools" ] && echo no || echo yes)"
    # What an earlier layout, or a job while it owned the root, left: repaired to root-owned 0755 with
    # no ACL, NRV-W1203; both roles; the role's own ci_mount_root call is what is under test, so the
    # branch's mount question is stood in for (as a real read-only main/ and a read-write branches/
    # would answer it), and a mutant that drops the call (`:`) is caught without a mount.
    chk_stub() { # chk_stub ROLE ROOT: the mount question answered as a branch's mounts would
        bash -c '. ci/cache.sh; r=$2; ci_cache_writable() { [ "$1" != "$r/main" ]; }; CI_JOB_USER=$3 ci_cache_check "$1" "$2"' _ "$1" "$2" "$jobuser" 2>&1
    }
    for role in main branch; do
        if [ "$role" = main ]; then sub=main; else sub=branches; fi
        for mode in 0755 0555 0000 0500 0600 0666 0200; do
            mk_roots "$tmp/w1203-$role-$mode"
            chown "$jobuser" "$tmp/w1203-$role-$mode/$sub"
            ci_as chmod "$mode" "$tmp/w1203-$role-$mode/$sub"
            if [ "$role" = main ]; then out=$(chk main "$tmp/w1203-$role-$mode" && echo RC0); else out=$(chk_stub branch "$tmp/w1203-$role-$mode" && echo RC0); fi || true
            grep -q "NRV-W1203: .*$sub, a mount root, was not root-owned 0755 with no ACL (owner $jobuser, mode $(printf '%o' $((8#$mode)))): set to it" <<<"$out" || { echo "FAIL $role's role, $sub/ owned by the job, mode $mode: no NRV-W1203: $out" >&2; fail=1; }
            grep -q RC0 <<<"$out" || { echo "FAIL $role's role, $sub/ owned by the job, mode $mode is refused: $out" >&2; fail=1; }
            ! grep -q "NRV-E12" <<<"$out" || { echo "FAIL $role's role, $sub/ owned by the job, mode $mode gives an error: $out" >&2; fail=1; }
            is "$role's role, $sub/ owned by the job, mode $mode: made root's, 0755" "0 755" "$(stat -c '%u %a' "$tmp/w1203-$role-$mode/$sub")"
            is "$role's role, $sub/ made root's: the job cannot write it" no "$(usable "$tmp/w1203-$role-$mode/$sub" && ci_as touch "$tmp/w1203-$role-$mode/$sub/x" 2>/dev/null && echo yes || echo no)"
        done
        # Root's own, with another mode (a host's chmod): back to 0755, the same warning.
        mk_roots "$tmp/w1203-rootmode-$role"
        chmod 0777 "$tmp/w1203-rootmode-$role/$sub"
        if [ "$role" = main ]; then out=$(chk main "$tmp/w1203-rootmode-$role" && echo RC0); else out=$(chk_stub branch "$tmp/w1203-rootmode-$role" && echo RC0); fi || true
        { grep -q "NRV-W1203: .*$sub, a mount root, was not root-owned 0755 with no ACL (owner root, mode 777)" <<<"$out" && grep -q RC0 <<<"$out"; } || { echo "FAIL $role's role, root-owned $sub/ mode 0777: $out" >&2; fail=1; }
        is "$role's role, root-owned $sub/ mode 0777: set to 0755" "0 755" "$(stat -c '%u %a' "$tmp/w1203-rootmode-$role/$sub")"
        # Not the step's and not the job's: nobody's to chown. E1229, untouched.
        if [ -n "$third" ]; then
            mk_roots "$tmp/foreign-$role"
            chown "$third" "$tmp/foreign-$role/$sub"
            chmod 0555 "$tmp/foreign-$role/$sub"
            if [ "$role" = main ]; then out=$(chk main "$tmp/foreign-$role" || true); else out=$(chk_stub branch "$tmp/foreign-$role" || true); fi
            grep -q "NRV-E1229: .*$sub is mounted read-write but is owned by neither this step's user nor the job's ($jobuser): owner $third, uid $(id -u "$third"), mode 555" <<<"$out" || { echo "FAIL $role's role, $sub/ owned by $third: $out" >&2; fail=1; }
            ! grep -q "NRV-W1203" <<<"$out" || { echo "FAIL $role's role, $sub/ owned by $third is 'repaired': $out" >&2; fail=1; }
            is "$role's role, $sub/ owned by $third: owner and mode untouched" "$(id -u "$third") 555" "$(stat -c '%u %a' "$tmp/foreign-$role/$sub")"
        else
            skip_note "a mount root owned by a third user (no daemon, bin or sys user here)"
        fi
        # An ACL on the root, a default one included (a job's, while it owned the root): removed with the rest.
        if [ "$acl_ok" = yes ]; then
            for owner in job root; do
                mk_roots "$tmp/acl-$role-$owner"
                if [ "$owner" = job ]; then chown "$jobuser" "$tmp/acl-$role-$owner/$sub"; fi
                setfacl -d -m u::---,g::---,o::--- "$tmp/acl-$role-$owner/$sub"
                setfacl -m u:"$jobuser":rwx "$tmp/acl-$role-$owner/$sub"
                has_acl "$tmp/acl-$role-$owner/$sub" || { echo "FAIL the ACL test did not set an ACL on $role's $sub/" >&2; fail=1; }
                if [ "$role" = main ]; then out=$(chk main "$tmp/acl-$role-$owner" && echo RC0); else out=$(chk_stub branch "$tmp/acl-$role-$owner" && echo RC0); fi || true
                { grep -q "NRV-W1203: .*$sub, a mount root, was not root-owned 0755 with no ACL (owner .*with an ACL): set to it" <<<"$out" && grep -q RC0 <<<"$out"; } || { echo "FAIL $role's role, $sub/ ($owner's) with an ACL: no NRV-W1203 and success: $out" >&2; fail=1; }
                is "$role's role, $sub/ ($owner's) with a default ACL: no ACL left, root's, 0755" "no 0 755" "$(has_acl "$tmp/acl-$role-$owner/$sub" && echo yes || echo no) $(stat -c '%u %a' "$tmp/acl-$role-$owner/$sub")"
                mkdir "$tmp/acl-$role-$owner/$sub/probe"
                is "$role's role, $sub/ ($owner's): a directory made in it afterwards has its mode, not the ACL's" 755 "$(stat -c %a "$tmp/acl-$role-$owner/$sub/probe")"
            done
        else
            echo "note: no ACL support here (setfacl missing, or the file system keeps none): the ACL tests of the mount roots were skipped" >&2
        fi
    done
    # A link at the mount root is never followed: the target keeps its mode. The link is made BY
    # THE JOB (review 6001089776): it is then owned by the job's uid, so `stat` of it matches the
    # job's and, without the `-L` test, root's chmod 0755 would follow it to the job's 0500 target.
    # (A link made by root is owned by root and never reaches that chmod: it proves nothing.)
    mk_roots "$tmp/linkroot"
    mkdir "$tmp/linkroot/target"
    chown "$jobuser" "$tmp/linkroot/target"
    ci_as chmod 0500 "$tmp/linkroot/target"
    rm -rf "$tmp/linkroot/main"
    chown "$jobuser" "$tmp/linkroot"
    ci_as ln -s target "$tmp/linkroot/main"
    chown root "$tmp/linkroot"
    is "(the link is the job's: owner)" "$jobuser" "$(stat -c %U "$tmp/linkroot/main")"
    out=$(chk main "$tmp/linkroot" || true)
    grep -q "NRV-E1229: .*main is mounted read-write but is a link, not a directory (it is never followed)" <<<"$out" || { echo "FAIL a link at main/: $out" >&2; fail=1; }
    ! grep -q "mode 777\|NRV-W1203" <<<"$out" || { echo "FAIL a link at main/ is reported by its own mode, or repaired: $out" >&2; fail=1; }
    is "a link at main/: its target keeps its mode" 500 "$(stat -c %a "$tmp/linkroot/target")"
    mk_roots "$tmp/e1229-ok"
    ok "main's role, main/ root's and rw" chk main "$tmp/e1229-ok"
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
        out=$(chk branch "$tmp/mnt" && echo RC0)
        is "branch's role: main/ a read-only mount, branches/ root's: accepted, nothing said" RC0 "$out"
        # A job-owned branches/ with a chmod: not "not mounted" (E1202); repaired with W1203, on a
        # real read-only main/ as well.
        chown "$jobuser" "$tmp/mnt/branches"
        ci_as chmod 0555 "$tmp/mnt/branches"
        out=$(chk branch "$tmp/mnt" && echo RC0)
        { grep -q "NRV-W1203: .*branches, a mount root, was not root-owned 0755 with no ACL (owner $jobuser, mode 555)" <<<"$out" && grep -q RC0 <<<"$out" && ! grep -q "NRV-E12" <<<"$out"; } || { echo "FAIL branches/ owned by the job, 0555 (read-only main/ mount): $out" >&2; fail=1; }
        is "branches/ owned by the job, 0555: repaired" "0 755" "$(stat -c '%u %a' "$tmp/mnt/branches")"
        if [ -n "$third" ]; then
            chown "$third" "$tmp/mnt/branches"
            chmod 0555 "$tmp/mnt/branches"
            out=$(chk branch "$tmp/mnt" || true)
            grep -q "NRV-E1229: .*branches is mounted read-write but is owned by neither" <<<"$out" || { echo "FAIL third user's 0555 branches/ (read-only main/ mount): $out" >&2; fail=1; }
            ! grep -q "NRV-E1202" <<<"$out" || { echo "FAIL third user's 0555 branches/ is called a mount error: $out" >&2; fail=1; }
        fi
        umount "$tmp/mnt/main"
        # Main's role with main/ read-only (root writes through a mode, so only a real mount shows it),
        # and a branch's with branches/ read-only: E1202, never E1229.
        mk_roots "$tmp/mnt2"
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

# What a job leaves in its own caches (rules 2 and 3 of ci/cache.sh). A job owns the direct children
# of a mount root (a branch's directory, main's zig, zig-local and tools) and everything below them,
# and is untrusted: whatever it does to them, the next pipeline must prepare them (rc=0) and the job
# must be able to make a directory in them that comes out usable. Rule 3: the job's own tree is
# normalized AS THE JOB before the job runs, so a `chmod 0555`, `0600`, `0000`, a default ACL, a FIFO
# or a socket, at the child or deep in it, costs nothing: no root operation follows it. Rule 2: what
# the job owns and cannot use whatever the normalization does (a file or a FIFO at the child itself,
# or a tree the normalization failed in) is removed by root (rm -rf of the one name) under the lock
# that keeps the other jobs out, with NRV-W1204, and made again. A foreign owner, or other jobs
# holding the lock a reset needs, is NRV-E1228, and nothing is touched. Root only: a second user.
if [ "$(id -u)" = 0 ]; then
    w_tree() { # w_tree NAME: a tree with a file, a 0555 subdirectory and a file in it, in each cache directory
        local r q
        r=$(attack_tree "$1")
        mk_branch "$r/branches/$branch_key"
        for q in main/zig main/zig-local main/tools "branches/$branch_key/zig" "branches/$branch_key/zig-local"; do
            ci_as mkdir -p "$r/$q/sub"
            ci_as touch "$r/$q/keep" "$r/$q/sub/f"
            ci_as chmod 0555 "$r/$q/sub"
        done
        echo "$r"
    }
    run_branch() { ( . ci/cache.sh; CI_JOB_USER=$jobuser CI_LOCK_WAIT=2 ci_branch_prepare "$1" feature/atk 2>&1 && echo RC0 ) || true; }
    run_main() { bash -c '. ci/cache.sh; CI_PRUNE_WAIT=1 ci_main_prepare "$1" "$2" no 0 2>&1 && echo RC0' _ "$1" "$jobuser" || true; }
    mkok() { # mkok DIR: the job makes a directory in DIR (and a file in that): yes if it comes out usable, no ACL
        ci_as mkdir "$1/mk" 2>/dev/null && usable "$1/mk" && ! has_acl "$1/mk" && ci_as touch "$1/mk/f" 2>/dev/null && echo yes
    }
    quiet() { # quiet OUT: the run succeeded and said no warning and no error
        grep -q RC0 <<<"$1" && ! grep -q "NRV-[EW]12" <<<"$1" && echo yes
    }
    stubdir() { # stubdir NAME BODY: a directory of stubs (a `timeout`, `mkdir`, `mktemp`) for PATH, readable by the job
        mkdir -p "$tmp/stub-$1"
        chmod 755 "$tmp/stub-$1"
        printf '#!/bin/sh\n%s\n' "$2" >"$tmp/stub-$1/${3:-timeout}"
        chmod 755 "$tmp/stub-$1/${3:-timeout}"
    }
    # A direct child with a mode that leaves it unusable to the job: not writable (0555) or not
    # searchable (0600, 0666, 0200: `test -w` alone says writable, review 6001444818). Normalization
    # opens it up (find acts on a directory before it enters it), silently, and keeps what is in it.
    for mode in 0555 0600 0666 0200 0000; do
        r=$(w_tree "wb-$mode")
        d="$r/branches/$branch_key"
        ci_as chmod "$mode" "$d"
        # In a subshell, to see its descriptors before it exits: the step keeps its shared lock on
        # fd 6 for the job's whole run, and a prune of another job must not be able to take it.
        out=$( (
            . ci/cache.sh
            CI_JOB_USER=$jobuser CI_LOCK_WAIT=2 ci_branch_prepare "$r" feature/atk 2>&1 && echo RC0
            flock -x -n "$r/locks/$branch_key.lock" true && echo LOCKFREE || echo LOCKHELD
        ) ) || true
        is "branch directory $mode: prepared with no warning and no error" yes "$(quiet "$out")"
        is "branch $mode: the lock on fd 6 is held to the end (a prune cannot take it)" LOCKHELD "$(grep -o 'LOCK[A-Z]*' <<<"$out")"
        is "branch $mode: the job's directory is usable, what was in it is kept, a directory made in it is usable" "yes yes yes yes 755" "$(usable "$d" && echo yes) $(mkok "$d/zig") $([ -e "$d/zig/keep" ] && echo yes) $([ -e "$d/zig/sub/f" ] && echo yes) $(stat -c %a "$d/zig/sub")"
    done
    for sub in zig zig-local tools; do
        for mode in 0555 0600 0666 0200 0000; do
            r=$(w_tree "wm-$sub-$mode")
            ci_as chmod "$mode" "$r/main/$sub"
            out=$(run_main "$r")
            is "main/$sub $mode: prepared with no warning and no error" yes "$(quiet "$out")"
            is "main/$sub $mode: usable, kept, the job's, a directory made in it is usable" "yes yes yes $jobuser" "$(usable "$r/main/$sub" && echo yes) $(mkok "$r/main/$sub") $([ -e "$r/main/$sub/keep" ] && echo yes) $(stat -c %U "$r/main/$sub")"
            for other in zig zig-local tools; do
                [ "$other" = "$sub" ] || is "main/$sub $mode: main/$other is left alone" yes "$([ -e "$r/main/$other/keep" ] && echo yes)"
            done
        done
    done
    # Deeper than a direct child: normalized the same way (it was NRV-E1228 before the job's tree was
    # normalized as the job). A branch's own zig and zig-local, main's zig/sub, in each bad mode.
    for mode in 0555 0600 0666 0200 0000; do
        r=$(w_tree "wd-$mode")
        d="$r/branches/$branch_key"
        ci_as chmod "$mode" "$d/zig" "$d/zig-local"
        out=$(run_branch "$r")
        is "branch zig and zig-local $mode: prepared with no warning and no error" yes "$(quiet "$out")"
        is "branch zig $mode: usable, kept, a directory made in it is usable" "yes yes yes" "$(mkok "$d/zig") $(mkok "$d/zig-local") $([ -e "$d/zig/keep" ] && echo yes)"
        r=$(w_tree "wd2-$mode")
        ci_as chmod "$mode" "$r/main/zig/sub"
        out=$(run_main "$r")
        is "main/zig/sub $mode: prepared with no warning and no error" yes "$(quiet "$out")"
        is "main/zig/sub $mode: opened up (u+rwx), kept, usable" "yes yes yes" "$([ -e "$r/main/zig/sub/f" ] && echo yes) $(usable "$r/main/zig/sub" && echo yes) $(mkok "$r/main/zig/sub")"
    done
    # A path deep in the job's tree at mode 0000 (main/zig/o/x, a branch's zig/p), with a file in it and a
    # FIFO beside it: opened up and kept, the FIFO removed, and the job can make a directory in it.
    for spec in main:zig/o/x branch:zig/p branch:zig-local/q/r; do
        role=${spec%%:*}
        rel=${spec#*:}
        r=$(w_tree "w0-$role")
        if [ "$role" = main ]; then base="$r/main"; else base="$r/branches/$branch_key"; fi
        ci_as mkdir -p "$base/$rel"
        ci_as touch "$base/$rel/data"
        ci_as mkfifo "$base/${rel%/*}/pipe"
        ci_as chmod 0000 "$base/$rel"
        if [ "$role" = main ]; then out=$(run_main "$r"); else out=$(run_branch "$r"); fi
        is "$role: $rel at mode 0000: prepared with no warning and no error" yes "$(quiet "$out")"
        is "$role: $rel at mode 0000: usable, its file kept, a directory made in it usable, the FIFO beside it removed" "yes yes yes no" "$(usable "$base/$rel" && echo yes) $(mkok "$base/$rel") $([ -e "$base/$rel/data" ] && echo yes) $([ -e "$base/${rel%/*}/pipe" ] && echo yes || echo no)"
    done
    # A default ACL set by the job on a child, or deep in the tree (a directory made in it would come
    # out with mode 000 and nothing could be made there): stripped as the job, the pipeline prepares,
    # and a directory made afterwards has its mode, not the ACL's.
    if [ "$acl_ok" = yes ]; then
        for spec in main:zig main:tools main:zig/o/x branch: branch:zig branch:zig/p; do
            role=${spec%%:*}
            rel=${spec#*:}
            r=$(w_tree "wacl-$role")
            if [ "$role" = main ]; then base="$r/main"; else base="$r/branches/$branch_key"; fi
            t="$base${rel:+/$rel}"
            ci_as mkdir -p "$t"
            ci_as setfacl -d -m u::---,g::---,o::--- "$t"
            has_acl "$t" || { echo "FAIL the ACL test did not set an ACL on $t" >&2; fail=1; }
            if [ "$role" = main ]; then out=$(run_main "$r"); else out=$(run_branch "$r"); fi
            is "$role: a default ACL on ${rel:-the branch directory}: prepared with no warning and no error" yes "$(quiet "$out")"
            is "$role: a default ACL on ${rel:-the branch directory}: no ACL left, usable, a directory made in it is usable with its mode" "no yes 755" "$(has_acl "$t" && echo yes || echo no) $(mkok "$t") $(stat -c %a "$t/mk")"
        done
    else
        echo "note: no ACL support here (setfacl missing, or the file system keeps none): the ACL tests of the job's caches were skipped" >&2
    fi
    # A normalization that fails (a stub `timeout` that fails the first time, as one that ran out of
    # time would): the child is removed by root under the exclusive lock, NRV-W1204, made again empty.
    # Both roles. The job's tree is not left half-normalized: nothing of it is kept.
    for role in branch main; do
        r=$(w_tree "wfail-$role")
        stubdir fail1 'if mkdir "$STUB_STATE" 2>/dev/null; then exit 1; fi
exec /usr/bin/timeout "$@"'
        mkdir -p "$tmp/stubshare"
        chmod 1777 "$tmp/stubshare"
        rm -rf "$tmp/stubshare/once-$role"
        if [ "$role" = branch ]; then
            d="$r/branches/$branch_key"
            out=$(PATH="$tmp/stub-fail1:$PATH" STUB_STATE="$tmp/stubshare/once-$role" run_branch "$r")
        else
            d="$r/main/zig"
            out=$(PATH="$tmp/stub-fail1:$PATH" STUB_STATE="$tmp/stubshare/once-$role" run_main "$r")
        fi
        grep -q "NRV-W1204: $d, owned by the job's user ($jobuser), was not a usable directory for it (writable and searchable; was: directory, mode 755)" <<<"$out" || { echo "FAIL $role: a normalization that fails: no NRV-W1204: $out" >&2; fail=1; }
        { grep -q RC0 <<<"$out" && ! grep -q "NRV-E12" <<<"$out"; } || { echo "FAIL $role: a normalization that fails is refused: $out" >&2; fail=1; }
        is "$role: a normalization that fails: made again, empty, the job's, usable" "yes no $jobuser" "$(usable "$d" && ci_as mkdir "$d/new" && echo yes) $([ -e "$d/keep" ] || [ -e "$d/zig/keep" ] && echo yes || echo no) $(stat -c %U "$d")"
    done
    # The same, with other jobs holding the lock a reset needs (shared, as every running step does):
    # nothing is removed, NRV-E1228 (the normalization that fails always, as a tree it cannot get through).
    stubdir fail 'exit 1'
    r=$(w_tree wbb)
    d="$r/branches/$branch_key"
    : >"$r/locks/$branch_key.lock"
    chmod 600 "$r/locks/$branch_key.lock"
    flock -s "$r/locks/$branch_key.lock" sleep 30 &
    holder=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do flock -x -n "$r/locks/$branch_key.lock" true 2>/dev/null || break; sleep 0.2; done
    out=$(PATH="$tmp/stub-fail:$PATH" run_branch "$r")
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    grep -q "NRV-E1228: $d" <<<"$out" || { echo "FAIL a branch directory in use by another job that cannot be normalized is not E1228: $out" >&2; fail=1; }
    ! grep -q "NRV-W1204\|RC0" <<<"$out" || { echo "FAIL a branch directory in use by another job is removed: $out" >&2; fail=1; }
    is "branch: in use by another job: kept as it was" "yes" "$([ -e "$d/zig/keep" ] && echo yes)"
    r=$(w_tree wmb)
    : >"$r/locks/main.lock"
    chmod 600 "$r/locks/main.lock"
    flock -s "$r/locks/main.lock" sleep 30 &
    holder=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do flock -x -n "$r/locks/main.lock" true 2>/dev/null || break; sleep 0.2; done
    out=$(PATH="$tmp/stub-fail:$PATH" run_main "$r")
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    grep -q "NRV-E1228: $r/main/zig" <<<"$out" || { echo "FAIL main/zig in use by other jobs that cannot be normalized is not E1228: $out" >&2; fail=1; }
    ! grep -q "NRV-W1204\|RC0" <<<"$out" || { echo "FAIL main/zig in use by other jobs is removed: $out" >&2; fail=1; }
    is "main/zig: other jobs hold main's lock: kept as it was" "yes" "$([ -e "$r/main/zig/keep" ] && echo yes)"
    # A foreign owner: root's own 0555 child is NRV-E1228 and is left exactly as it was.
    for sub in zig tools; do
        r=$(w_tree wf-$sub)
        chown root "$r/main/$sub"
        chmod 0555 "$r/main/$sub"
        out=$(run_main "$r")
        { grep -q "NRV-E1228: $r/main/$sub" <<<"$out" && ! grep -q "NRV-W1204\|RC0" <<<"$out"; } || { echo "FAIL a root-owned 0555 main/$sub: $out" >&2; fail=1; }
        is "main/$sub owned by root, 0555: kept as it was" "0 555 yes" "$(stat -c '%u %a' "$r/main/$sub") $([ -e "$r/main/$sub/keep" ] && echo yes)"
    done
    r=$(w_tree wfb)
    d="$r/branches/$branch_key"
    chown root "$d"
    chmod 0555 "$d"
    out=$(run_branch "$r")
    { grep -q "NRV-E1228: $d" <<<"$out" && ! grep -q "NRV-W1204\|RC0" <<<"$out"; } || { echo "FAIL a root-owned 0555 branch directory: $out" >&2; fail=1; }
    is "branch directory owned by root, 0555: kept as it was" "0 555 yes" "$(stat -c '%u %a' "$d") $([ -e "$d/zig/keep" ] && echo yes)"
    # A branch directory that cannot be made (a full disk; here a failing mkdir and mktemp): NRV-E1214
    # says it could not be made, not that something is in the way.
    stubdir nomk 'exit 1' mkdir
    stubdir nomk 'exit 1' mktemp
    r=$(attack_tree e1214mk)
    out=$(PATH="$tmp/stub-nomk:$PATH" run_branch "$r")
    { grep -q "NRV-E1214: $r/branches/$branch_key could not be made in $r/branches" <<<"$out" && ! grep -q "is not a directory\|RC0" <<<"$out"; } || { echo "FAIL a branch directory that cannot be made: E1214 does not say so: $out" >&2; fail=1; }
    # ci_child_reset itself refuses what is not a direct child of the mount, and a link.
    r=$(w_tree wr)
    ( . ci/cache.sh; CI_JOB_USER=$jobuser ci_child_reset "$r/main/zig/sub" "$r/main" ) >/dev/null 2>&1 && { echo "FAIL ci_child_reset removed a grandchild" >&2; fail=1; }
    is "ci_child_reset: a grandchild is kept" "yes" "$([ -e "$r/main/zig/sub/f" ] && echo yes)"
    ci_as chmod 0555 "$r/main/zig"
    plant link "$r/branches/zlink" "$r/main/zig"
    ( . ci/cache.sh; CI_JOB_USER=$jobuser ci_child_reset "$r/branches/zlink" "$r/branches" ) >/dev/null 2>&1 && { echo "FAIL ci_child_reset followed a link" >&2; fail=1; }
    is "ci_child_reset: a link to an unwritable directory is not followed" "yes" "$([ -e "$r/main/zig/keep" ] && echo yes)"
else
    skip_note "the repair of a cache directory the job made unusable (NRV-W1204, E1228)"
fi

# --- Review 6002160899 (the nineteenth round): the normalization under concurrent jobs, the types
# and modes it fixes, the lock round the mkdir and the chown, and `reset-cache`. The job's user is
# `nobody` as root, else this user; as anyone else the tests that need a second user are skipped.
prep_b() { ( . ci/cache.sh; CI_JOB_USER=$jobuser CI_LOCK_WAIT=2 ci_branch_prepare "$1" feature/atk 2>&1 && echo RC0 ) || true; }
prep_m() { bash -c '. ci/cache.sh; CI_PRUNE_WAIT=1 ci_main_prepare "$1" "$2" no 0 2>&1 && echo RC0' _ "$1" "$jobuser" || true; }
job_writes() { ci_as sh -c ': >>"$1"' _ "$1" 2>/dev/null && echo yes || echo no; }
churn_stop="$tmp/churn-stop"
churn_start() { # churn_start DIR: as the job, what Zig does in a cache (a tmp/<x> renamed into o/, the old ones removed), until churn_end
    : >"$churn_stop"
    chmod 644 "$churn_stop"
    ci_as bash -c 'cd "$1" && mkdir -p tmp o && i=0 && while [ -e "$2" ]; do mkdir tmp/t$i; : >tmp/t$i/f; mv tmp/t$i o/n$i; [ "$i" -lt 50 ] || rm -rf "o/n$((i - 50))"; i=$((i + 1)); done' _ "$1" "$churn_stop" &
    churn_pid=$!
}
churn_end() {
    rm -f "$churn_stop"
    wait "$churn_pid" 2>/dev/null || true
}
# The walk races other jobs of the same key (a push starts about 14 steps on one key): entries that
# vanish while find is at them are no failure, and say nothing. find's own exit status was the
# verdict, and was 1 then (review finding 4649956141): 20 tries, all rc 0 and no output.
r=$(attack_tree churn)
churn_start "$r/main/zig"
churn_bad=
for i in $(seq 20); do
    churn_rc=0
    churn_out=$( (. ci/cache.sh; CI_JOB_USER=$jobuser ci_normalize "$r/main/zig") 2>&1) || churn_rc=$?
    if [ "$churn_rc" != 0 ] || [ -n "$churn_out" ]; then churn_bad="try $i: rc $churn_rc: $churn_out"; break; fi
done
churn_end
is "normalization of a tree another process churns: rc 0 and silent, 20 times" "" "$churn_bad"
# The same, made certain: a `find` that exits 1 after an entry "vanished" (what GNU find does, about
# one walk in fifty under that churn; the option does not stop it) is no failure either.
mkdir -p "$tmp/stub-find"
chmod 755 "$tmp/stub-find"
printf '#!/bin/sh\n%s "$@"\necho "find: ./gone: No such file or directory" >&2\nexit 1\n' "$(command -v find)" >"$tmp/stub-find/find"
chmod 755 "$tmp/stub-find/find"
r=$(attack_tree findstub)
ci_as mkdir "$r/main/zig/sub"
ci_as chmod 0000 "$r/main/zig/sub"
churn_rc=0
churn_out=$( (. ci/cache.sh; PATH="$tmp/stub-find:$PATH" CI_JOB_USER=$jobuser ci_normalize "$r/main/zig") 2>&1) || churn_rc=$?
is "normalization with a find that exits 1 on a vanished entry: rc 0, silent, and the walk still did its work" "0  yes" "$churn_rc $churn_out $(ci_as test -x "$r/main/zig/sub" && echo yes)"
# End to end: the branch's lock is held shared by another job (as every running step does) and the
# tree is churned: a second ci_branch_prepare succeeds. It could not reset the tree (the exclusive
# lock is not free), so a failed normalization was E1228.
r=$(attack_tree churn2)
prep_b "$r" >/dev/null
d="$r/branches/$branch_key"
flock -s "$r/locks/$branch_key.lock" sleep 60 &
holder=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do flock -x -n "$r/locks/$branch_key.lock" true 2>/dev/null || break; sleep 0.2; done
churn_start "$d/zig"
churn_bad=
for i in 1 2 3 4 5; do
    churn_out=$(prep_b "$r")
    if ! grep -q RC0 <<<"$churn_out" || grep -q "NRV-[EW]12" <<<"$churn_out"; then churn_bad="try $i: $churn_out"; break; fi
done
churn_end
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
is "branch prepared again while another job holds its lock shared and the tree is churned: 5 times, no E1228" "" "$churn_bad"

# The modes and the types a job leaves in its own caches. A file the job cannot write (a read-only
# Zig manifest) breaks the next build, a file where Zig makes a directory (h, o, z, p, tmp, b) breaks
# every build. Normalization gives files u+rw and removes a non-directory at those names, below
# main's zig and zig-local and a branch's zig and zig-local; a socket is removed. What is deeper
# than that is the job's own, not chased (the header of ci/cache.sh).
for role in main branch; do
    r=$(attack_tree "types-$role")
    if [ "$role" = main ]; then
        base="$r/main"
        sub1=zig-local
        sub2=zig
    else
        base="$r/branches/$branch_key"
        mk_branch "$base"
        sub1=zig
        sub2=zig-local
    fi
    ci_as mkdir -p "$base/$sub1/h" "$base/$sub1/o/deep" "$base/$sub2/z"
    ci_as touch "$base/$sub1/h/manifest" "$base/$sub1/o/deep/f"
    ci_as chmod 0400 "$base/$sub1/h/manifest" "$base/$sub1/o/deep/f"
    # A plain file, and a link to a directory of root's, at names Zig makes directories at.
    ci_as touch "$base/$sub2/p" "$base/$sub2/tmp"
    ci_as rm -f "$base/$sub2/tmp"
    ci_as ln -s "$sd" "$base/$sub2/tmp"
    ci_as touch "$base/$sub2/b"
    if [ "$role" = main ]; then out=$(prep_m "$r"); else out=$(prep_b "$r"); fi
    is "$role: a 0400 file in h and in o/deep, a file at p and b, a link at tmp: prepared with no warning and no error" yes "$(grep -q RC0 <<<"$out" && ! grep -q "NRV-[EW]12" <<<"$out" && echo yes)"
    is "$role: the 0400 files can be written now (h/manifest, o/deep/f)" "yes yes" "$(job_writes "$base/$sub1/h/manifest") $(job_writes "$base/$sub1/o/deep/f")"
    is "$role: the file at p and b and the link at tmp are gone, and the job can make a directory at each" "yes yes yes" "$(ci_as mkdir "$base/$sub2/p" "$base/$sub2/b" "$base/$sub2/tmp" 2>/dev/null && echo yes) $([ -d "$base/$sub2/tmp" ] && [ ! -L "$base/$sub2/tmp" ] && echo yes) $([ -z "$(ls -A "$sd")" ] && echo yes)"
    is "$role: the link's target was left alone" "$want_state" "$(sentinel_state)"
done
# A plain file at zig-local/h (main) and zig/h (a branch) alone, and nothing else in the tree.
for spec in main:zig-local branch:zig; do
    role=${spec%%:*}
    sub=${spec#*:}
    r=$(attack_tree "file-h-$role")
    if [ "$role" = main ]; then base="$r/main"; else base="$r/branches/$branch_key"; mk_branch "$base"; fi
    ci_as touch "$base/$sub/h"
    if [ "$role" = main ]; then out=$(prep_m "$r"); else out=$(prep_b "$r"); fi
    is "$role: a plain file at $sub/h: prepared with no warning and no error, removed, and the job can make the directory" "yes yes" "$(grep -q RC0 <<<"$out" && ! grep -q "NRV-[EW]12" <<<"$out" && echo yes) $(ci_as mkdir "$base/$sub/h" 2>/dev/null && echo yes)"
done
# A socket (a mutant that drops `-o -type s` leaves it): made by python, bound in its directory (the
# path of a socket is short).
if command -v python3 >/dev/null; then
    for role in main branch; do
        r=$(attack_tree "sock-$role")
        if [ "$role" = main ]; then base="$r/main/zig"; else mk_branch "$r/branches/$branch_key"; base="$r/branches/$branch_key/zig"; fi
        ci_as mkdir -p "$base/o/x"
        ci_as sh -c 'cd "$1" && python3 -I -c "import socket; socket.socket(socket.AF_UNIX).bind(\"sock\")"' _ "$base/o/x"
        [ -S "$base/o/x/sock" ] || { echo "FAIL $role: the test could not make a socket" >&2; fail=1; }
        if [ "$role" = main ]; then out=$(prep_m "$r"); else out=$(prep_b "$r"); fi
        is "$role: a socket deep in the tree: prepared with no warning and no error, and the socket is removed" "yes no" "$(grep -q RC0 <<<"$out" && ! grep -q "NRV-[EW]12" <<<"$out" && echo yes) $([ -S "$base/o/x/sock" ] && echo yes || echo no)"
    done
else
    echo "note: no python3: the socket test was skipped" >&2
fi
# ci_known_dirs: what the layout fixes (no other child is touched).
is "ci_known_dirs: main/zig" "b h o p tmp z" "$( . ci/cache.sh; ci_known_dirs /x/main/zig | tr '\n' ' ' | sed 's/ $//')"
is "ci_known_dirs: tools has none" "" "$( . ci/cache.sh; ci_known_dirs /x/main/tools)"
is "ci_known_dirs: a branch's directory has the six names under each of zig and zig-local" 12 "$( . ci/cache.sh; ci_known_dirs /x/branches/b-k-12345678 | wc -l | tr -d ' ')"

if [ "$(id -u)" = 0 ]; then
    # The window between root's mkdir and chown of a child. A fresh main/: 14 steps at once (a push
    # starts about 14 on one key) each prepare zig, zig-local and tools; none is refused (E1228
    # was the answer to 171 of 420 of them), 10 rounds.
    stress_bad=
    for round in 1 2 3 4 5 6 7 8 9 10; do
        r=$(attack_tree "stress")
        rm -rf "${r:?}/main/zig" "${r:?}/main/zig-local" "${r:?}/main/tools"
        pids=()
        for i in $(seq 14); do
            ( prep_m "$r" >"$tmp/stress-$i.out" ) &
            pids+=($!)
        done
        wait "${pids[@]}" 2>/dev/null || true
        for i in $(seq 14); do
            if ! grep -q RC0 "$tmp/stress-$i.out" || grep -q "NRV-[EW]12" "$tmp/stress-$i.out"; then
                stress_bad="round $round, step $i: $(head -3 "$tmp/stress-$i.out")"
                break 2
            fi
        done
        is "stress round $round: the three directories are the job's" "$jobuser $jobuser $jobuser" "$(stat -c %U "$r/main/zig" "$r/main/zig-local" "$r/main/tools" | tr '\n' ' ' | sed 's/ $//')"
    done
    is "14 concurrent prepares of a fresh main, 10 rounds: none refused" "" "$stress_bad"
    # The two things the stress depends on, each on its own. ci_child_make takes a directory that is
    # not the job's for somebody else's, and says so (return 1), and makes one that is not there.
    r=$(attack_tree mk)
    mkdir "$r/main/rootsdir"
    ( . ci/cache.sh; CI_JOB_USER=$jobuser ci_child_make "$r/main/rootsdir" ) >/dev/null 2>&1 && { echo "FAIL ci_child_make accepted a directory another uid owns" >&2; fail=1; }
    ( . ci/cache.sh; CI_JOB_USER=$jobuser ci_child_make "$r/main/zig" ) >/dev/null 2>&1 || { echo "FAIL ci_child_make refused the job's own directory" >&2; fail=1; }
    ( . ci/cache.sh; CI_JOB_USER=$jobuser ci_child_make "$r/main/fresh" ) >/dev/null 2>&1 || { echo "FAIL ci_child_make did not make a directory" >&2; fail=1; }
    is "ci_child_make: a new directory is the job's" "$jobuser" "$(stat -c %U "$r/main/fresh")"
    # A step that finds a root-owned directory (another step is between its mkdir and its chown) waits
    # for the lock that step holds, then finds it the job's: here a holder that chowns after a second.
    mkdir "$r/main/half"
    : >"$r/locks/main-children.lock"
    chmod 600 "$r/locks/main-children.lock"
    ( flock -x 4 && sleep 1.5 && chown "$jobuser" "$r/main/half" ) 4>>"$r/locks/main-children.lock" &
    holder=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do flock -x -n "$r/locks/main-children.lock" true 2>/dev/null || break; sleep 0.2; done
    probe_rc=0
    ( . ci/cache.sh; CI_JOB_USER=$jobuser ci_child_probe "$r/main/half" ) >/dev/null 2>&1 || probe_rc=$?
    wait "$holder" 2>/dev/null || true
    is "ci_child_probe of a root-owned directory waits for the lock of the step that is making it (rc 0)" 0 "$probe_rc"
    # NRV-E1234: a lock that is not let go does not hold a step up for good. Nothing is made.
    ( flock -x 4 && sleep 8 ) 4>>"$r/locks/main-children.lock" &
    holder=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do flock -x -n "$r/locks/main-children.lock" true 2>/dev/null || break; sleep 0.2; done
    out=$( (. ci/cache.sh; CI_JOB_USER=$jobuser CI_CHILD_LOCK_WAIT=1 ci_child_make "$r/main/never") 2>&1) && { echo "FAIL ci_child_make with the lock held went on: $out" >&2; fail=1; }
    grep -q "NRV-E1234: the lock $r/locks/main-children.lock.* was held for 1 s" <<<"$out" || { echo "FAIL a children lock that is not let go is not E1234: $out" >&2; fail=1; }
    is "E1234: nothing was made while the lock was held" no "$([ -e "$r/main/never" ] && echo yes || echo no)"
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
else
    skip_note "the children lock's tests (a second user is the job's: the window between mkdir and chown, NRV-E1234)"
fi

# `nerva-woodpecker.sh reset-cache`: empties one cache at once, under the lock that keeps pipelines
# out, as the prune does. Any user (the scratch root is this user's, as root's is on the box).
rc_run() { env NERVA_CI_CACHE_ROOT="$1" "${@:3}" bash ops/ci/nerva-woodpecker.sh reset-cache "${@:2:1}" 2>&1; }
rc_tree() { # rc_tree NAME: a cache root with main (zig, zig-local, tools), two branches and the locks, a 0555 directory and a link in each
    local q="$tmp/rc-$1"
    rm -rf "$q"
    mkdir -p "$q/main/zig/o/deep" "$q/main/zig-local" "$q/main/tools" "$q/branches/$branch_key/zig" "$q/branches/b-other-12345678/zig"
    chmod 0755 "$q" "$q/main" "$q/branches"
    mkdir -m 0700 "$q/locks"
    : >"$q/main/zig/o/deep/f"
    : >"$q/main/tools/archive"
    : >"$q/branches/$branch_key/zig/f"
    : >"$q/branches/b-other-12345678/zig/f"
    ln -s "$sd" "$q/main/zig/o/link"
    ln -s "$sd" "$q/branches/$branch_key/zig/link"
    [ "$(id -u)" = 0 ] && chmod 0555 "$q/main/zig/o/deep" "$q/branches/$branch_key/zig"
    echo "$q"
}
q=$(rc_tree m)
out=$(rc_run "$q" main) || { echo "FAIL reset-cache main: $out" >&2; fail=1; }
grep -q "nerva-woodpecker: OK reset-cache main" <<<"$out" || { echo "FAIL reset-cache main: no OK line: $out" >&2; fail=1; }
is "reset-cache main: zig and zig-local gone, tools and the branches kept, the link's target kept" "no no yes yes yes $want_state" "$([ -e "$q/main/zig" ] && echo yes || echo no) $([ -e "$q/main/zig-local" ] && echo yes || echo no) $([ -e "$q/main/tools/archive" ] && echo yes) $([ -e "$q/branches/$branch_key/zig/f" ] && echo yes) $([ -d "$q/main" ] && echo yes) $(sentinel_state)"
out=$(rc_run "$q" main) || { echo "FAIL reset-cache main again (nothing to remove): $out" >&2; fail=1; }
q=$(rc_tree b)
out=$(rc_run "$q" feature/atk) || { echo "FAIL reset-cache BRANCH: $out" >&2; fail=1; }
is "reset-cache BRANCH: that branch's directory gone, the other branch's and main's kept, the link's target kept" "no yes yes $want_state" "$([ -e "$q/branches/$branch_key" ] && echo yes || echo no) $([ -e "$q/branches/b-other-12345678/zig/f" ] && echo yes) $([ -e "$q/main/zig/o/deep/f" ] && echo yes) $(sentinel_state)"
reset_sentinels
refuses NRV-E1221 "reset-cache without an argument" env NERVA_CI_CACHE_ROOT="$q" bash ops/ci/nerva-woodpecker.sh reset-cache
refuses NRV-E1221 "reset-cache with two arguments" env NERVA_CI_CACHE_ROOT="$q" bash ops/ci/nerva-woodpecker.sh reset-cache main x
refuses NRV-E1221 "reset-cache with a wait that is not a number" env NERVA_CI_CACHE_ROOT="$q" NERVA_CI_RESET_WAIT=soon bash ops/ci/nerva-woodpecker.sh reset-cache main
# NRV-E1235: pipelines hold the lock (shared, as every running step does): nothing is removed.
q=$(rc_tree busy)
: >"$q/locks/main.lock"
chmod 600 "$q/locks/main.lock"
flock -s "$q/locks/main.lock" sleep 20 &
holder=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do flock -x -n "$q/locks/main.lock" true 2>/dev/null || break; sleep 0.2; done
out=$(rc_run "$q" main NERVA_CI_RESET_WAIT=1) && { echo "FAIL reset-cache went on with a pipeline running: $out" >&2; fail=1; }
grep -q "NRV-E1235: main's cache is in use" <<<"$out" || { echo "FAIL reset-cache with a pipeline running is not E1235: $out" >&2; fail=1; }
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
is "reset-cache with a pipeline running: nothing removed" yes "$([ -e "$q/main/zig/o/deep/f" ] && echo yes)"
# The children lock too (a step in the middle of making a directory).
q=$(rc_tree busy2)
: >"$q/locks/main-children.lock"
chmod 600 "$q/locks/main-children.lock"
flock -x "$q/locks/main-children.lock" sleep 20 &
holder=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do flock -x -n "$q/locks/main-children.lock" true 2>/dev/null || break; sleep 0.2; done
out=$(rc_run "$q" main NERVA_CI_RESET_WAIT=1) && { echo "FAIL reset-cache went on with the children lock held: $out" >&2; fail=1; }
grep -q "NRV-E1235" <<<"$out" || { echo "FAIL reset-cache with the children lock held is not E1235: $out" >&2; fail=1; }
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
is "reset-cache with the children lock held: nothing removed" yes "$([ -e "$q/main/zig/o/deep/f" ] && echo yes)"
# A mount root another user can write (a job's, as an earlier layout left it) is not acted in.
q=$(rc_tree open)
chmod 0777 "$q/main"
out=$(rc_run "$q" main) && { echo "FAIL reset-cache acted in a mount root others can write: $out" >&2; fail=1; }
grep -q "NRV-E1235" <<<"$out" || { echo "FAIL reset-cache in a writable mount root is not E1235: $out" >&2; fail=1; }
chmod 0755 "$q/main"
# An ACL that gives a job write access, which the mode does not show (skipped where the filesystem has none).
if setfacl -m u:nobody:rwx,m::r-x "$q/main" 2>/dev/null && [ "$(find "$q/main" -maxdepth 0 -perm /022 | wc -l)" = 0 ]; then
    out=$(rc_run "$q" main) && { echo "FAIL reset-cache acted in a mount root with an ACL: $out" >&2; fail=1; }
    grep -q "NRV-E1235" <<<"$out" || { echo "FAIL reset-cache in a mount root with an ACL is not E1235: $out" >&2; fail=1; }
    is "reset-cache in a mount root with an ACL: nothing removed" yes "$([ -e "$q/main/zig/o/deep/f" ] && echo yes)"
    setfacl -b "$q/main"
fi
chmod 0755 "$q/locks"
out=$(rc_run "$q" main) && { echo "FAIL reset-cache accepted a lock directory others can use: $out" >&2; fail=1; }
grep -q "NRV-E1235" <<<"$out" || { echo "FAIL reset-cache with an open lock directory is not E1235: $out" >&2; fail=1; }
is "reset-cache in an unsafe root or lock directory: nothing removed" yes "$([ -e "$q/main/zig/o/deep/f" ] && echo yes)"
chmod 0700 "$q/locks"
rm -rf "$q/main"
ln -s "$sd" "$q/main"
out=$(rc_run "$q" main) && { echo "FAIL reset-cache followed a link as the mount root: $out" >&2; fail=1; }
is "reset-cache with a link as the mount root: refused, the target kept" "$want_state" "$(sentinel_state)"
# The branch key is ci/cache.sh's, for names with slashes, odd characters and past the length cut.
for name in feature/atk a/b a_b 'x y' "$(printf 'long-%.0s' $(seq 20))"; do
    q=$(rc_tree key)
    k=$(. ci/cache.sh; ci_branch_key "$name")
    mkdir -p "$q/branches/$k/zig"
    : >"$q/branches/$k/zig/f"
    rc_run "$q" "$name" >/dev/null || { echo "FAIL reset-cache '$name'" >&2; fail=1; }
    is "reset-cache '$name' removes the directory ci_branch_key names" no "$([ -e "$q/branches/$k" ] && echo yes || echo no)"
done

# --- Review 6002726986 (the twentieth round): the locks a step holds while it walks a tree, `reset-cache`
# against a step, what `reset-cache` can reach, and the knobs. The job's user is `nobody` as root.
wait_for() { local i; for i in $(seq 100); do [ -e "$1" ] && return 0; sleep 0.1; done; return 1; } # wait_for FILE
# A `find` that waits the first time the job's walk (ci_normalize) runs it (a poisoned and large tree, in
# effect), says so in a marker, and then runs the real one.
slow="$tmp/slow-find"
mark="$tmp/slow-mark"
mkdir -p "$slow" "$mark"
chmod 755 "$slow"
chmod 777 "$mark"
cat >"$slow/find" <<EOS
#!/bin/sh
case "\$*" in *-ignore_readdir_race*) if [ ! -e "$mark/started" ]; then : >"$mark/started"; sleep "\${SLOW_FIND:-3}"; fi ;; esac
exec $(command -v find) "\$@"
EOS
chmod 755 "$slow/find"
now() { date +%s.%N; }
slow_reset() { rm -f "$mark"/*; }

# The branch's step does not hold the branches' lock (fd 7) or main's (fd 9) while the job's tree is
# walked: another branch's step is not held up (NRV-W1202 after CI_LOCK_WAIT) and main's prune is
# not either. The step is started holding fd 9 shared, as woodpecker_step.sh does.
r=$(attack_tree slowwalk)
: >"$r/locks/main.lock"
chmod 600 "$r/locks/main.lock"
(. ci/cache.sh; CI_JOB_USER=$jobuser CI_LOCK_WAIT=2 ci_branch_prepare "$r" feature/slow) >/dev/null 2>&1 || { echo "FAIL the first prepare of feature/slow" >&2; fail=1; }
slow_reset
(
    exec 9<"$r/locks/main.lock"
    flock -s 9
    . ci/cache.sh
    PATH="$slow:$PATH" CI_JOB_USER=$jobuser CI_LOCK_WAIT=2 ci_branch_prepare "$r" feature/slow >"$tmp/slow-a.out" 2>&1 && echo RC0 >>"$tmp/slow-a.out"
) &
slow_pid=$!
wait_for "$mark/started" || { echo "FAIL the slow walk never started" >&2; fail=1; }
is "a branch's walk of its tree holds neither the branches' lock nor main's" "free free" "$(flock -x -n "$r/locks/branches.lock" true && echo -n free || echo -n held; echo -n ' '; flock -x -n "$r/locks/main.lock" true && echo free || echo held)"
t0=$(now)
out=$( (. ci/cache.sh; CI_JOB_USER=$jobuser CI_LOCK_WAIT=1 ci_branch_prepare "$r" feature/fast 2>&1 && echo RC0) || true)
t1=$(now)
is "another branch's step is prepared while the first walks its tree: RC0, no warning" yes "$(grep -q RC0 <<<"$out" && ! grep -q "NRV-[EW]12" <<<"$out" && echo yes)"
is "and quickly (under 2.5 s while the walk waits 3 s)" yes "$(awk -v a="$t0" -v b="$t1" 'BEGIN { print (b - a < 2.5) ? "yes" : "no" }')"
wait "$slow_pid" 2>/dev/null || true
is "the slow step itself finished (RC0, no warning)" yes "$(grep -q RC0 "$tmp/slow-a.out" && ! grep -q "NRV-[EW]12" "$tmp/slow-a.out" && echo yes)"
# A damaged directory is still prepared once the locks are let go (the walk fixes the mode).
r=$(attack_tree slowreset)
mk_branch "$r/branches/$branch_key"
ci_as touch "$r/branches/$branch_key/zig/h"
ci_as chmod 0 "$r/branches/$branch_key/zig-local"
out=$(prep_b "$r")
is "a branch directory prepared after its tree was damaged: RC0 and usable" yes "$(grep -q RC0 <<<"$out" && usable "$r/branches/$branch_key/zig-local" && echo yes)"

# The walk batches its chmod of files: 40 files at mode 0400 cost a few chmod processes, not 40 (a
# fork per file made 20 000 of them take 26.7 s). A stub `chmod` counts its calls.
mkdir -p "$tmp/count-chmod"
chmod 755 "$tmp/count-chmod"
printf '#!/bin/sh\necho x >>"%s/chmod.log"\nexec %s "$@"\n' "$mark" "$(command -v chmod)" >"$tmp/count-chmod/chmod"
chmod 755 "$tmp/count-chmod/chmod"
r=$(attack_tree batch)
ci_as mkdir "$r/main/zig/o"
for i in $(seq 40); do ci_as touch "$r/main/zig/o/f$i"; done
ci_as chmod 0400 "$r/main/zig/o"/f*
slow_reset
(. ci/cache.sh; PATH="$tmp/count-chmod:$PATH" CI_JOB_USER=$jobuser ci_normalize "$r/main/zig") >/dev/null 2>&1
is "normalization: 40 files at 0400 are writable now, with fewer than 10 chmod calls" "yes yes" "$(job_writes "$r/main/zig/o/f1") $(job_writes "$r/main/zig/o/f40")"
is "normalization batches its chmod of files" yes "$([ "$(wc -l <"$mark/chmod.log")" -lt 10 ] && echo yes)"

# A walk that leaves a known name wrong is judged by what it leaves (the verdict, step 4): `rm` is a
# stub that removes nothing, so a file at a name Zig needs to be a directory stays, and the tree is
# not usable (probe rc 11). With the step's own reset also unable to remove it, the step is refused
# (NRV-E1228) and does not go on with a directory that would fail every build.
mkdir -p "$tmp/rm-noop"
chmod 755 "$tmp/rm-noop"
printf '#!/bin/sh\nexit 0\n' >"$tmp/rm-noop/rm"
cp "$tmp/rm-noop/rm" "$tmp/rm-noop/mv" # the reset's move aside does nothing either
chmod 755 "$tmp/rm-noop/rm" "$tmp/rm-noop/mv"
r=$(attack_tree verdict)
ci_as touch "$r/main/zig/h"
probe_rc=0
(. ci/cache.sh; PATH="$tmp/rm-noop:$PATH" CI_JOB_USER=$jobuser ci_child_probe "$r/main/zig") >/dev/null 2>&1 || probe_rc=$?
is "the verdict: a file left at zig/h after the walk is rc 11" 11 "$probe_rc"
out=$(PATH="$tmp/rm-noop:$PATH" prep_m "$r")
grep -q "NRV-E1228: $r/main/zig is not a directory" <<<"$out" && ! grep -q RC0 <<<"$out" || { echo "FAIL a tree whose walk left a known name wrong and could not be reset is not E1228: $out" >&2; fail=1; }
# The same with the reset able to work: W1204, made again, the step goes on.
if [ "$(id -u)" = 0 ]; then # as one user, the stub cannot tell root's rm from the job's
    rm -f "$tmp/rm-noop/mv" # root's reset (a move aside) works again; only the job's rm does nothing
    r=$(attack_tree verdict2)
    ci_as touch "$r/main/zig/h"
    printf '#!/bin/sh\ncase "$(id -u)" in 0) exec %s "$@" ;; *) exit 0 ;; esac\n' "$(command -v rm)" >"$tmp/rm-noop/rm"
    out=$(PATH="$tmp/rm-noop:$PATH" prep_m "$r")
    is "the verdict: the job's rm does nothing, root's reset removes it and says so (W1204), the step goes on" "yes yes" "$(grep -q "NRV-W1204: $r/main/zig" <<<"$out" && echo yes) $(grep -q RC0 <<<"$out" && echo yes)"
fi

# `reset-cache` against a main step. The step holds main's lock shared from before its first probe,
# so a reset waits for it (never meets a directory that is half prepared) and a step that starts
# while the reset holds the lock waits for the reset: neither is NRV-E1228.
r=$(attack_tree race2)
slow_reset
(
    . ci/cache.sh
    PATH="$slow:$PATH" CI_PRUNE_WAIT=1 ci_main_prepare "$r" "$jobuser" no 0 >"$tmp/race-m.out" 2>&1 && echo RC0 >>"$tmp/race-m.out"
    now >"$tmp/race-m.end"
) &
race_pid=$!
wait_for "$mark/started" || { echo "FAIL the main step's slow walk never started" >&2; fail=1; }
is "a main step holds main's lock shared while it probes: an exclusive try fails" busy "$(flock -x -n "$r/locks/main.lock" true && echo free || echo busy)"
out=$(rc_run "$r" main NERVA_CI_RESET_WAIT=20) || { echo "FAIL reset-cache racing a main step: $out" >&2; fail=1; }
now >"$tmp/race-r.end"
wait "$race_pid" 2>/dev/null || true
is "reset-cache racing a main step: the step is prepared (RC0), neither is E1228" yes "$(grep -q RC0 "$tmp/race-m.out" && ! grep -q "NRV-E" "$tmp/race-m.out" && ! grep -q NRV-E <<<"$out" && echo yes)"
is "reset-cache waited for the step (it ended after it)" yes "$(awk -v a="$(cat "$tmp/race-m.end")" -v b="$(cat "$tmp/race-r.end")" 'BEGIN { print (b >= a) ? "yes" : "no" }')"
# And the other way round: the reset holds the lock, a step that starts waits for it.
r=$(attack_tree race3)
: >"$r/locks/main.lock"
chmod 600 "$r/locks/main.lock"
flock -x "$r/locks/main.lock" sleep 2 &
holder=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do flock -x -n "$r/locks/main.lock" true 2>/dev/null || break; sleep 0.2; done
t0=$(now)
out=$(prep_m "$r")
t1=$(now)
wait "$holder" 2>/dev/null || true
is "a main step started while the lock is held exclusively waits for it and is prepared" "yes yes" "$(grep -q RC0 <<<"$out" && ! grep -q "NRV-E" <<<"$out" && echo yes) $(awk -v a="$t0" -v b="$t1" 'BEGIN { print (b - a >= 1) ? "yes" : "no" }')"

# `reset-cache` holds the locks only for the renames: the children lock and the cache's own lock
# are free while the moved-aside trees are removed (an `rm` stub that waits shows it), and the
# trash is empty at the end. A tree left in locks/trash by a run that crashed is removed by the
# next one, and `host` removes it.
q=$(rc_tree trash)
mkdir -p "$q/locks/trash/zig.crashed/deep"
: >"$q/locks/trash/zig.crashed/deep/f"
mkdir -p "$tmp/slow-rm"
chmod 755 "$tmp/slow-rm"
printf '#!/bin/sh\n: >"%s/rm-started"\nsleep 2\nexec %s "$@"\n' "$mark" "$(command -v rm)" >"$tmp/slow-rm/rm"
chmod 755 "$tmp/slow-rm/rm"
slow_reset
(rc_run "$q" main PATH="$tmp/slow-rm:$PATH" >"$tmp/rc-trash.out" 2>&1 || true) &
rc_pid=$!
wait_for "$mark/rm-started" || { echo "FAIL the trash was never emptied" >&2; fail=1; }
is "reset-cache: the cache is gone and both locks are free while the trash is being emptied" "no free free" "$([ -e "$q/main/zig" ] && echo -n yes || echo -n no; echo -n ' '; flock -x -n "$q/locks/main.lock" true && echo -n free || echo -n held; echo -n ' '; flock -x -n "$q/locks/main-children.lock" true && echo free || echo held)"
wait "$rc_pid" 2>/dev/null || true
grep -q "OK reset-cache main" "$tmp/rc-trash.out" || { echo "FAIL reset-cache with a slow rm: $(cat "$tmp/rc-trash.out")" >&2; fail=1; }
is "reset-cache: the trash is empty afterwards, a crashed run's tree included" "" "$(ls -A "$q/locks/trash")"
mkdir -p "$q/locks/trash/zig.crashed2"
: >"$q/locks/trash/zig.crashed2/f"
out=$(rc_run "$q" main) || { echo "FAIL reset-cache after a crashed run: $out" >&2; fail=1; }
is "reset-cache again removes what a crashed run left" "" "$(ls -A "$q/locks/trash")"
rm -rf "$q/locks/trash"
ln -s "$sd" "$q/locks/trash"
out=$(rc_run "$q" main) && { echo "FAIL reset-cache followed a link as locks/trash: $out" >&2; fail=1; }
grep -q "NRV-E1235: .*trash is not a directory" <<<"$out" || { echo "FAIL a link as locks/trash is not E1235: $out" >&2; fail=1; }
is "a link as locks/trash: the target is left alone" "$want_state" "$(sentinel_state)"

# What `reset-cache` reaches: a manual pipeline on main runs in the branch role (key b-main-<sum>),
# which `main` does not reach and `--branch main` does; jepsen's tools; a branch with `--branch`.
q=$(rc_tree manual)
mk=$(. ci/cache.sh; ci_branch_key main)
mkdir -p "$q/branches/$mk/zig" "$q/jepsen/tools" "$q/jepsen/20260101T000000Z-1"
chmod 0755 "$q/jepsen"
: >"$q/branches/$mk/zig/f"
: >"$q/jepsen/tools/docker"
: >"$q/jepsen/20260101T000000Z-1/store"
out=$(rc_run "$q" main) || { echo "FAIL reset-cache main: $out" >&2; fail=1; }
is "reset-cache main does not reach a manual pipeline's cache (key $mk)" yes "$([ -e "$q/branches/$mk/zig/f" ] && echo yes)"
out=$(env NERVA_CI_CACHE_ROOT="$q" bash ops/ci/nerva-woodpecker.sh reset-cache --branch main 2>&1) || { echo "FAIL reset-cache --branch main: $out" >&2; fail=1; }
is "reset-cache --branch main removes it, and only it" "no yes yes" "$([ -e "$q/branches/$mk" ] && echo yes || echo no) $([ -e "$q/branches/$branch_key/zig/f" ] && echo yes) $([ -e "$q/main/tools/archive" ] && echo yes)"
out=$(rc_run "$q" jepsen) || { echo "FAIL reset-cache jepsen: $out" >&2; fail=1; }
is "reset-cache jepsen removes the tools and keeps the runs' stores" "no yes" "$([ -e "$q/jepsen/tools" ] && echo yes || echo no) $([ -e "$q/jepsen/20260101T000000Z-1/store" ] && echo yes)"
kj=$(. ci/cache.sh; ci_branch_key jepsen)
mkdir -p "$q/branches/$kj/zig"
out=$(env NERVA_CI_CACHE_ROOT="$q" bash ops/ci/nerva-woodpecker.sh reset-cache --branch jepsen 2>&1) || { echo "FAIL reset-cache --branch jepsen: $out" >&2; fail=1; }
is "reset-cache --branch jepsen is the branch named jepsen, not the jepsen cache" "no" "$([ -e "$q/branches/$kj" ] && echo yes || echo no)"
refuses NRV-E1221 "reset-cache --branch without a name" env NERVA_CI_CACHE_ROOT="$q" bash ops/ci/nerva-woodpecker.sh reset-cache --branch
refuses NRV-E1221 "reset-cache --branch with two names" env NERVA_CI_CACHE_ROOT="$q" bash ops/ci/nerva-woodpecker.sh reset-cache --branch a b
# The jepsen lock is held for a whole run: a reset waits, then says so.
: >"$q/locks/jepsen.lock"
chmod 600 "$q/locks/jepsen.lock"
mkdir -p "$q/jepsen/tools"
flock -x "$q/locks/jepsen.lock" sleep 10 &
holder=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do flock -x -n "$q/locks/jepsen.lock" true 2>/dev/null || break; sleep 0.2; done
out=$(rc_run "$q" jepsen NERVA_CI_RESET_WAIT=1) && { echo "FAIL reset-cache jepsen went on during a Jepsen run: $out" >&2; fail=1; }
grep -q "NRV-E1235: jepsen's cache is in use" <<<"$out" || { echo "FAIL reset-cache jepsen during a run is not E1235: $out" >&2; fail=1; }
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
is "reset-cache jepsen during a run: nothing removed" yes "$([ -e "$q/jepsen/tools" ] && echo yes)"

# An ACL on the mount root or on locks/ (the mode does not show it: it can give a job write access)
# is refused like a writable mode (NRV-E1235), as the step refuses it (NRV-E1229).
if command -v setfacl >/dev/null && [ "$(id -u)" = 0 ]; then
    q=$(rc_tree acl)
    if setfacl -m "u:$jobuser:rwx" "$q/main" 2>/dev/null && has_acl "$q/main"; then
        out=$(rc_run "$q" main) && { echo "FAIL reset-cache acted in a mount root with an ACL: $out" >&2; fail=1; }
        grep -q "NRV-E1235: .*with no ACL" <<<"$out" || { echo "FAIL reset-cache in a mount root with an ACL is not E1235: $out" >&2; fail=1; }
        setfacl -b "$q/main"
        setfacl -m "u:$jobuser:x" "$q/locks"
        out=$(rc_run "$q" main) && { echo "FAIL reset-cache acted with an ACL on locks/: $out" >&2; fail=1; }
        grep -q "NRV-E1235" <<<"$out" || { echo "FAIL reset-cache with an ACL on locks/ is not E1235: $out" >&2; fail=1; }
        setfacl -b "$q/locks"
        is "reset-cache with an ACL on a mount root or on locks/: nothing removed" yes "$([ -e "$q/main/zig/o/deep/f" ] && echo yes)"
        out=$(rc_run "$q" main) || { echo "FAIL reset-cache after the ACLs were removed: $out" >&2; fail=1; }
    else
        echo "note: this file system takes no ACLs: the reset-cache ACL test was skipped" >&2
    fi
else
    skip_note "the reset-cache ACL test (needs root and setfacl)"
fi

# NRV-B1202: ci_normalize and ci_job_dir act on a job's own tree as the job's user, never as root:
# a root step whose job user is unset or root refuses (a bug in the caller), and touches nothing.
if [ "$(id -u)" = 0 ]; then
    r=$(attack_tree b1202)
    ci_as touch "$r/main/zig/h"
    for who in unset root; do
        if [ "$who" = unset ]; then envv=(env -u CI_JOB_USER); else envv=(env CI_JOB_USER=root); fi
        refuses NRV-B1202 "ci_normalize as root with the job user $who" "${envv[@]}" bash -c '. ci/cache.sh; ci_normalize "$1"' _ "$r/main/zig"
        refuses NRV-B1202 "ci_job_dir as root with the job user $who" "${envv[@]}" bash -c '. ci/cache.sh; ci_job_dir "$1"' _ "$r/main/zig/sub"
    done
    is "ci_normalize and ci_job_dir refused as root touched nothing" "yes no" "$([ -e "$r/main/zig/h" ] && echo yes) $([ -e "$r/main/zig/sub" ] && echo yes || echo no)"
    ok "ci_normalize with the job user set" env CI_JOB_USER="$jobuser" bash -c '. ci/cache.sh; ci_normalize "$1"' _ "$r/main/zig"
else
    skip_note "NRV-B1202 (root with an unset job user)"
fi

# NRV-E1208 for the two knobs a root step passes to timeout(1) and flock -w: a whole number of
# seconds, 1 or more. A zero would be no limit (timeout) or no wait (flock), and an expression an
# error from a tool run as root.
r=$(attack_tree knobs)
for bad in 0 abc '1;touch x' -5 1.5 ' 3' 9999999; do
    refuses NRV-E1208 "CI_NORMALIZE_SECONDS='$bad'" env CI_NORMALIZE_SECONDS="$bad" CI_JOB_USER="$jobuser" bash -c '. ci/cache.sh; ci_normalize "$1"' _ "$r/main/zig"
    refuses NRV-E1208 "CI_CHILD_LOCK_WAIT='$bad'" env CI_CHILD_LOCK_WAIT="$bad" CI_JOB_USER="$jobuser" bash -c '. ci/cache.sh; ci_child_make "$1"' _ "$r/main/zig-new"
done
is "a refused knob made nothing" no "$([ -e "$r/main/zig-new" ] && echo yes || echo no)"
ok "CI_NORMALIZE_SECONDS=5 is accepted" env CI_NORMALIZE_SECONDS=5 CI_JOB_USER="$jobuser" bash -c '. ci/cache.sh; ci_normalize "$1"' _ "$r/main/zig"
ok "CI_CHILD_LOCK_WAIT=5 is accepted" env CI_CHILD_LOCK_WAIT=5 CI_JOB_USER="$jobuser" bash -c '. ci/cache.sh; ci_child_make "$1"' _ "$r/main/zig-new"

# Lock files a prune makes are the step's own, 0600 (they used to be 0644 by root's umask, and a
# job that could list a 0755 lock directory could take them), and a lock directory with any group
# or other bit is refused (NRV-E1226): what Docker makes of a missing mount source is root 0755.
r=$(attack_tree p)
plant dir "$r/branches/b-pruned-00000004"
plant dir "$r/branches/b-big-00000005"
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

# --- Review 6003115432 (the twenty-first round): root never walks a tree a job made while it holds a
# lock other steps wait on. Under a lock root only decides and renames into MOUNT/.trash
# (ci_trash_move); it removes the trash (ci_trash_empty) after the lock is let go. The job's user
# is `nobody` as root, else this user.
real_rm=$(command -v rm)
real_du=$(command -v du)
real_df=$(command -v df)
real_find=$(command -v find)
real_mktemp=$(command -v mktemp)
mkdir -p "$tmp/stubs"
chmod 755 "$tmp/stubs"
# A stub for NAME that runs the real command after SCRIPT (a shell snippet, with $mark and $SPY_* known).
mkstub() { # mkstub NAME REAL BODY
    mkdir -p "$tmp/stubs/$1"
    chmod 755 "$tmp/stubs/$1"
    printf '#!/bin/sh\n%s\nexec %s "$@"\n' "$3" "$2" >"$tmp/stubs/$1/$1"
    chmod 755 "$tmp/stubs/$1/$1"
}
# rm: the first `rm -rf` of the run waits (a large tree being removed), and says so in a marker.
mkstub rm "$real_rm" "case \"\$*\" in *-rf*) if [ ! -e \"$mark/rm-started\" ]; then : >\"$mark/rm-started\"; sleep \"\${SLOW_RM:-2}\"; fi ;; esac"
# du: the first one waits.
mkstub du "$real_du" "if [ ! -e \"$mark/du-started\" ]; then : >\"$mark/du-started\"; sleep \"\${SLOW_DU:-2}\"; fi"
# Spies (root only: a job cannot open the lock directory): every rm and du that root runs logs which
# lock files somebody holds EXCLUSIVELY (a shared try fails: excl:<name>) and whether the branches'
# lock or main's is held at all (an exclusive try fails: any:<name>).
spy_body='if [ "$(id -u)" = 0 ] && [ -n "${SPY_LOCKS:-}" ]; then s=; for f in "$SPY_LOCKS"/*.lock; do n=$(basename "$f" .lock); case "$n" in *-trash) continue ;; esac; flock -s -n "$f" true 2>/dev/null || s="$s excl:$n"; done; flock -x -n "$SPY_LOCKS/branches.lock" true 2>/dev/null || s="$s any:branches"; echo "NAME$s :: $*" >>"$SPY_LOG"; fi'
mkstub spyrm "$real_rm" "${spy_body//NAME/rm}"
mkstub spydu "$real_du" "${spy_body//NAME/du}"
mkdir -p "$tmp/stubs/spy"
chmod 755 "$tmp/stubs/spy"
cp "$tmp/stubs/spyrm/spyrm" "$tmp/stubs/spy/rm"
cp "$tmp/stubs/spydu/spydu" "$tmp/stubs/spy/du"
spy_path="$tmp/stubs/spy"
# find: waits when the walk is of a poisoned zig-local (a file `poison` in it), as a large tree would.
mkstub find "$real_find" "case \"\$1\" in */zig-local) [ ! -e \"\$1/poison\" ] || sleep 3 ;; esac"
# df: the inode table says IT inodes with IF free; the blocks are the real ones.
mkstub df "$real_df" "case \"\$*\" in *-Pi*) printf 'Filesystem Inodes IUsed IFree IUse%% Mounted on\nstub %s 1 %s 99%% /\n' \"\${IT:-1000000}\" \"\${IF:-1000000}\"; exit 0 ;; esac"
# mktemp: the first box ci_trash_move makes is removed again at once, as a concurrent step's
# ci_trash_empty could.
mkstub mktemp "$real_mktemp" "case \"\$*\" in *.trash/t.*) if [ ! -e \"$mark/mk-once\" ]; then : >\"$mark/mk-once\"; d=\$($real_mktemp \"\$@\") || exit 1; rmdir \"\$d\"; echo \"\$d\"; exit 0; fi ;; esac"
slow_rm_dir="$tmp/stubs/rm"
slow_du_dir="$tmp/stubs/du"
fakefind_dir="$tmp/stubs/find"
fakedf_dir="$tmp/stubs/df"
mkmv_dir="$tmp/stubs/mktemp"
nsel() { grep -c "$1" "$2" 2>/dev/null || true; }

# (a) Another branch's step is prepared (the branches' lock and main's are free, no NRV-W1202) while
# one step's reset is removing a tree: the poisoned directory is a file, so the step holds the
# branches' lock for its reset, which only renames; the first `rm -rf` (the trash's) waits 3 s.
r=$(attack_tree trashrm)
plant file "$r/branches/$branch_key"
: >"$r/locks/main.lock"
chmod 600 "$r/locks/main.lock"
slow_reset
(
    exec 9<"$r/locks/main.lock"
    flock -s 9
    . ci/cache.sh
    PATH="$slow_rm_dir:$PATH" SLOW_RM=3 CI_JOB_USER=$jobuser CI_LOCK_WAIT=2 ci_branch_prepare "$r" feature/atk >"$tmp/trashrm-a.out" 2>&1 && echo RC0 >>"$tmp/trashrm-a.out"
) &
trashrm_pid=$!
wait_for "$mark/rm-started" || { echo "FAIL the trash was never emptied (a)" >&2; fail=1; }
is "a reset removing a tree holds neither the branches' lock nor main's" "free free" "$(flock -x -n "$r/locks/branches.lock" true && echo -n free || echo -n held; echo -n ' '; flock -x -n "$r/locks/main.lock" true && echo free || echo held)"
t0=$(now)
out=$( (. ci/cache.sh; CI_JOB_USER=$jobuser CI_LOCK_WAIT=1 ci_branch_prepare "$r" feature/other 2>&1 && echo RC0) || true)
t1=$(now)
is "another branch's prepare while a reset's tree is removed: RC0 and no warning" yes "$(grep -q RC0 <<<"$out" && ! grep -q "NRV-[EW]12" <<<"$out" && echo yes)"
is "and quickly (under 2.5 s while the removal waits 3 s)" yes "$(awk -v a="$t0" -v b="$t1" 'BEGIN { print (b - a < 2.5) ? "yes" : "no" }')"
wait "$trashrm_pid" 2>/dev/null || true
is "the resetting step itself: W1204, RC0, a usable directory made again" yes "$(grep -q "NRV-W1204: $r/branches/$branch_key" "$tmp/trashrm-a.out" && grep -q RC0 "$tmp/trashrm-a.out" && usable "$r/branches/$branch_key/zig" && echo yes)"
is "and the trash is empty afterwards" "" "$(ls -A "$r/branches/.trash")"

# (b) A step's prune and measure keep the branches' lock short whatever another branch's cache
# holds: the other cache is old (dropped: moved, then removed after the lock) and the step's own
# size is measured after the lock (du waits 2 s the first time). A second step waits at most
# CI_LOCK_WAIT=1 s for the lock, so it would get NRV-W1202 if either ran under it.
r=$(attack_tree prunefast)
plant dir "$r/branches/b-big-00000001"
ci_as mkdir -p "$r/branches/b-big-00000001/zig/o/deep"
for i in $(seq 50); do ci_as touch "$r/branches/b-big-00000001/zig/o/deep/f$i"; done
touch -d "20 days ago" "$r/branches/b-big-00000001"
: >"$r/locks/main.lock"
chmod 600 "$r/locks/main.lock"
slow_reset
(
    exec 9<"$r/locks/main.lock"
    flock -s 9
    . ci/cache.sh
    PATH="$slow_rm_dir:$slow_du_dir:$PATH" SLOW_RM=2 SLOW_DU=2 CI_JOB_USER=$jobuser CI_LOCK_WAIT=2 ci_branch_prepare "$r" feature/atk >"$tmp/prunefast-a.out" 2>&1 && echo RC0 >>"$tmp/prunefast-a.out"
) &
prunefast_pid=$!
wait_for "$mark/rm-started" || { echo "FAIL the pruned tree was never removed (b)" >&2; fail=1; }
out=$( (. ci/cache.sh; CI_JOB_USER=$jobuser CI_LOCK_WAIT=1 ci_branch_prepare "$r" feature/d1 2>&1 && echo RC0) || true)
is "(b) a prepare while a pruned tree is removed: RC0, no NRV-W1202" yes "$(grep -q RC0 <<<"$out" && ! grep -q "NRV-[EW]12" <<<"$out" && echo yes)"
wait_for "$mark/du-started" || { echo "FAIL the step's own size was never measured (b)" >&2; fail=1; }
out=$( (. ci/cache.sh; CI_JOB_USER=$jobuser CI_LOCK_WAIT=1 ci_branch_prepare "$r" feature/d2 2>&1 && echo RC0) || true)
is "(b) a prepare while another step measures its cache: RC0, no NRV-W1202" yes "$(grep -q RC0 <<<"$out" && ! grep -q "NRV-[EW]12" <<<"$out" && echo yes)"
wait "$prunefast_pid" 2>/dev/null || true
is "(b) the old cache was dropped and the trash emptied" "no " "$([ -e "$r/branches/b-big-00000001" ] && echo yes || echo no) $(ls -A "$r/branches/.trash")"
is "(b) the step's own size was recorded" yes "$([ -s "$r/locks/$branch_key.size" ] && echo yes)"

# A spy on every `rm` and `du` that root runs: none of them runs while any lock is held
# exclusively (the key's, the branches', main's, the children lock), nor, without a seed, while
# the branches' lock or main's is held at all. The scenario: an old cache, a name that is no
# branch's, a killed seed's partial directory, a cache whose recorded size is over the bound, and the
# step's own directory a file (so the reset runs). Root only: a job cannot open the lock directory.
if [ "$(id -u)" = 0 ]; then
    r=$(attack_tree spy)
    plant dir "$r/branches/b-old-00000002"
    ci_as mkdir -p "$r/branches/b-old-00000002/zig/o"
    ci_as touch "$r/branches/b-old-00000002/zig/o/f"
    touch -d "20 days ago" "$r/branches/b-old-00000002"
    plant dir "$r/branches/b-odd name-00000003"
    plant dir "$r/branches/b-fat-00000004"
    echo 999999 >"$r/locks/b-fat-00000004.size"
    plant dir "$r/branches/$branch_key.partial.abcdef"
    plant file "$r/branches/$branch_key"
    : >"$r/locks/main.lock"
    chmod 600 "$r/locks/main.lock"
    spy_log="$tmp/spy.log"
    : >"$spy_log"
    chmod 666 "$spy_log"
    out=$(
        exec 9<"$r/locks/main.lock"
        flock -s 9
        . ci/cache.sh
        PATH="$spy_path:$PATH" SPY_LOCKS="$r/locks" SPY_LOG="$spy_log" CI_BRANCH_CACHES=2 CI_JOB_USER=$jobuser CI_LOCK_WAIT=2 ci_branch_prepare "$r" feature/atk 2>&1 && echo RC0
    ) || true
    is "spy: the prepare worked (RC0), and the old, odd, fat and partial names are gone" "yes no no no no" "$(grep -q RC0 <<<"$out" && echo yes) $([ -e "$r/branches/b-old-00000002" ] && echo yes || echo no) $([ -e "$r/branches/b-odd name-00000003" ] && echo yes || echo no) $([ -e "$r/branches/b-fat-00000004" ] && echo yes || echo no) $([ -e "$r/branches/$branch_key.partial.abcdef" ] && echo yes || echo no)"
    is "spy: root ran an rm and a du" "yes yes" "$(grep -q '^rm' "$spy_log" && echo yes) $(grep -q '^du' "$spy_log" && echo yes)"
    is "spy: no root rm or du ran while a lock was held exclusively, or the branches' at all" "0" "$(grep -v '^rm .*:: -f ' "$spy_log" | grep -c -e excl: -e any: || true)"
    # A seed: the size of main's package cache is measured (du) before the branches' lock, and the
    # copy itself is the job's.
    r=$(attack_tree spyseed)
    ci_as mkdir -p "$r/main/zig/p/pkg"
    ci_as touch "$r/main/zig/p/pkg/f"
    : >"$r/locks/main.lock"
    chmod 600 "$r/locks/main.lock"
    : >"$spy_log"
    out=$(
        exec 9<"$r/locks/main.lock"
        flock -s 9
        . ci/cache.sh
        PATH="$spy_path:$PATH" SPY_LOCKS="$r/locks" SPY_LOG="$spy_log" CI_JOB_USER=$jobuser CI_LOCK_WAIT=2 ci_branch_prepare "$r" feature/atk 2>&1 && echo RC0
    ) || true
    is "spy (seed): seeded (RC0), main's size was measured, and no du ran under the branches' lock" "yes yes 0" "$(grep -q RC0 <<<"$out" && [ -e "$r/branches/$branch_key/zig/p/pkg/f" ] && echo yes) $(grep -c '^du.*main/zig/p' "$spy_log" | sed 's/^[1-9].*/yes/') $(grep -c -e any:branches -e excl: "$spy_log" || true)"
    # The same for main: the prune and a reset of a poisoned child only rename under the exclusive lock.
    r=$(attack_tree spym)
    rm -rf "$r/main/zig-local"
    : >"$r/main/zig-local"
    chown "$jobuser" "$r/main/zig-local"
    ci_as mkdir -p "$r/main/zig/o/deep"
    ci_as touch "$r/main/zig/o/deep/f"
    : >"$spy_log"
    out=$(PATH="$spy_path:$PATH" SPY_LOCKS="$r/locks" SPY_LOG="$spy_log" CI_PRUNE_WAIT=2 bash -c '. ci/cache.sh; ci_main_prepare "$1" "$2" yes 0 2>&1 && echo RC0' _ "$r" "$jobuser" || true)
    is "spy (main): low-disk prune and a poisoned child: RC0" yes "$(grep -q RC0 <<<"$out" && echo yes)"
    is "spy (main): root's rm ran, and never while a lock was held exclusively" "yes 0" "$(grep -q '^rm' "$spy_log" && echo yes) $(grep -c excl: "$spy_log" || true)"
else
    skip_note "the spy on root's rm and du while a lock is held"
fi

# (c) Two steps of one push find main's zig-local poisoned at once (its walk times out): they do not
# refuse each other (NRV-E1228). Resetting is a rename under the exclusive lock, so the one that
# loses the conversion finds the other's fresh directory. The walk of a poisoned zig-local waits 3 s
# (the find stub) and CI_NORMALIZE_SECONDS=1; a reset that removed the tree under the lock instead
# (the first `rm -rf` waits 3 s) would hold the other past its 1 s wait for the lock.
for round in 1 2; do
    r=$(attack_tree concurrent$round)
    ci_as touch "$r/main/zig-local/poison"
    slow_reset
    (PATH="$slow_rm_dir:$fakefind_dir:$PATH" SLOW_RM=3 CI_NORMALIZE_SECONDS=1 prep_m "$r" >"$tmp/conc-a.out" 2>&1) &
    conc_a=$!
    (PATH="$slow_rm_dir:$fakefind_dir:$PATH" SLOW_RM=3 CI_NORMALIZE_SECONDS=1 prep_m "$r" >"$tmp/conc-b.out" 2>&1) &
    conc_b=$!
    wait "$conc_a" 2>/dev/null || true
    wait "$conc_b" 2>/dev/null || true
    is "two concurrent main prepares of a poisoned zig-local (round $round): both RC0, neither refused" "yes yes" "$(grep -q RC0 "$tmp/conc-a.out" && ! grep -q NRV-E "$tmp/conc-a.out" && echo yes) $(grep -q RC0 "$tmp/conc-b.out" && ! grep -q NRV-E "$tmp/conc-b.out" && echo yes)"
    is "and the directory is fresh and usable" yes "$([ ! -e "$r/main/zig-local/poison" ] && usable "$r/main/zig-local" && echo yes)"
done

# (d) The shared lock is taken again for each of main's directories: after a reset of zig (which
# holds the lock exclusively) the walks of zig-local and tools run under the SHARED one. A file at
# zig is reset; zig-local's walk waits 3 s (the slow find stub, first walk), and an exclusive try
# of the lock then fails (a shared holder) while a shared try works.
r=$(attack_tree retake)
rm -rf "$r/main/zig"
: >"$r/main/zig"
chown "$jobuser" "$r/main/zig"
slow_reset
(PATH="$slow:$PATH" prep_m "$r" >"$tmp/retake.out" 2>&1) &
retake_pid=$!
wait_for "$mark/started" || { echo "FAIL the walk of zig-local never started (d)" >&2; fail=1; }
is "(d) while zig-local is walked after zig's reset the lock is held shared, not exclusively" "shared" "$(flock -s -n "$r/locks/main.lock" true && echo shared || echo exclusive)"
wait "$retake_pid" 2>/dev/null || true
is "(d) the step is prepared, zig made again (W1204)" yes "$(grep -q RC0 "$tmp/retake.out" && grep -q "NRV-W1204: $r/main/zig" "$tmp/retake.out" && echo yes)"

# (e) The low-disk test watches inodes too (a job's empty files cost no blocks): ci_disk_low with a df
# that says few inodes are free is low, with plenty or no count not; CI_MIN_FREE_INODES moves the
# threshold; and the prune that follows empties main's Zig caches.
low() { (. ci/cache.sh; PATH="$fakedf_dir:$PATH" ci_disk_low "$tmp" 0) && echo low || echo ok; } # inherits IT and IF
is "inodes: 5 of 1,000,000 free is low (blocks are plentiful)" low "$(IT=1000000 IF=5 low)"
is "inodes: 500,000 free is not low" ok "$(IT=1000000 IF=500000 low)"
is "inodes: 500,000 free is low under CI_MIN_FREE_INODES=600000" low "$(CI_MIN_FREE_INODES=600000 IT=1000000 IF=500000 low)"
is "inodes: no inode count (0, or -: btrfs) has no inode test" "ok ok" "$(IT=0 IF=0 low) $(IT=- IF=- low)"
is "blocks: the real df still decides when the blocks are short" low "$( (. ci/cache.sh; PATH="$fakedf_dir:$PATH" IT=1000000 IF=500000 ci_disk_low "$tmp" 999999999) && echo low || echo ok)"
r=$(attack_tree inodes)
ci_as touch "$r/main/zig/f"
out=$(PATH="$fakedf_dir:$PATH" IT=1000000 IF=5 CI_PRUNE_WAIT=1 bash -c '. ci/cache.sh; ci_main_lock_open "$1" && ci_main_prune "$1" 0 && ci_trash_empty "$1/main"' _ "$r" 2>&1)
is "inodes low: main's prune empties zig (the step's low-disk path)" "yes no" "$(grep -q "emptying main's Zig caches" <<<"$out" && echo yes) $([ -e "$r/main/zig/f" ] && echo yes || echo no)"
r=$(attack_tree inodes2)
ci_as touch "$r/main/zig/f"
out=$(PATH="$fakedf_dir:$PATH" IT=1000000 IF=500000 CI_PRUNE_WAIT=1 bash -c '. ci/cache.sh; ci_main_lock_open "$1" && ci_main_prune "$1" 0' _ "$r" 2>&1)
is "inodes plentiful: not pruned" "yes yes" "$(grep -q "space is free again" <<<"$out" && echo yes) $([ -e "$r/main/zig/f" ] && echo yes)"

# (e2) A trash that is still being emptied makes the box look low (its blocks and inodes count as
# used): the low-disk prunes do not run then, or every step would move fresh caches into the trash
# (review 6004317640). What says so is state in locks/, which every step mounts and no job writes
# (review 6004471230): a marker locks/<mount>-trash.pending that the first ci_trash_move into a trash
# wrote less than CI_TRASH_PENDING_MINUTES (60) ago (later moves leave it alone; a running removal
# alone holds nothing off: review 6004714906), for main, branches and jepsen. The trashes' contents are not looked at (a branch step cannot
# empty main/.trash; a main step does not mount branches/). The rm that empties a trash is a stub
# that fails, so the trash stays; df says the box is low. Each case has its mutant (worklog/O4.md).
mkdir -p "$tmp/stubs/norm"
chmod 755 "$tmp/stubs/norm"
printf '#!/bin/sh\nexit 1\n' >"$tmp/stubs/norm/rm"
chmod 755 "$tmp/stubs/norm/rm"
prep_low_main() { # prep_low_main ROOT: a main prepare on a box that df says is low; prints its output and RC0
    PATH="$tmp/stubs/norm:$fakedf_dir:$PATH" IT=1000000 IF=5 bash -c '. ci/cache.sh; CI_PRUNE_WAIT=1 ci_main_prepare "$1" "$2" yes 0 2>&1 && echo RC0' _ "$1" "$jobuser" || true
}
prep_all_branch() { # prep_all_branch ROOT: a branch prepare with CI_BRANCH_PRUNE_ALL=1; prints its output and RC0
    PATH="$tmp/stubs/norm:$PATH" CI_BRANCH_PRUNE_ALL=1 bash -c '. ci/cache.sh; CI_JOB_USER=$1 CI_LOCK_WAIT=2 ci_branch_prepare "$2" feature/atk 2>&1 && echo RC0' _ "$jobuser" "$1" || true
}
pending_age() { # pending_age FILE MINUTES: sets the marker's mtime that many minutes in the past
    touch -d "$2 minutes ago" "$1"
}

# A prune that moved something into main/.trash left a marker, and a main prepare on a low box keeps
# main/zig (twice), prints NRV-W1206 and goes on. Mutant: the `elif ci_trash_hold_off` line removed.
r=$(attack_tree draining)
ci_as touch "$r/main/zig/f"
(. ci/cache.sh; CI_JOB_USER=$jobuser ci_trash_move "$r/main/zig-local") && mkdir "$r/main/zig-local"
chown "$jobuser" "$r/main/zig-local" 2>/dev/null || true
is "ci_trash_move wrote the mount's marker, in locks/, root's" "yes 600" "$([ -f "$r/locks/main-trash.pending" ] && echo yes) $(stat -c %a "$r/locks/main-trash.pending")"
for n in 1 2; do
    out=$(prep_low_main "$r")
    is "a fresh marker, box low: main prepare $n does not prune main/zig, says NRV-W1206, goes on" "yes yes yes" "$([ -e "$r/main/zig/f" ] && echo yes) $(grep -q "NRV-W1206: not pruning main's Zig caches: a trash is being emptied" <<<"$out" && echo yes) $(grep -q RC0 <<<"$out" && echo yes)"
done
# The same for a branch's prune of every idle cache (CI_BRANCH_PRUNE_ALL=1). Mutant: the branch `if` made false.
r=$(attack_tree draining-b)
mk_branch "$r/branches/b-idle-00000003"
plant dir "$r/branches/b-gone-00000009"
(. ci/cache.sh; CI_JOB_USER=$jobuser ci_trash_move "$r/branches/b-gone-00000009")
for n in 1 2; do
    out=$(prep_all_branch "$r")
    is "a fresh marker, prune-all: branch prepare $n keeps the idle branch's cache, says NRV-W1206" "yes yes yes" "$([ -d "$r/branches/b-idle-00000003" ] && echo yes) $(grep -q "NRV-W1206: not pruning every idle branch cache" <<<"$out" && echo yes) $(grep -q RC0 <<<"$out" && echo yes)"
done
r=$(attack_tree draining-c)
mk_branch "$r/branches/b-idle-00000003"
out=$(prep_all_branch "$r")
is "no trash and no marker, prune-all: the idle branch's cache is dropped (the low-disk backstop works)" "no" "$([ -d "$r/branches/b-idle-00000003" ] && echo yes || echo no)"

# (e2-1) The MUST of review 6004471230: a leftover in main/.trash, which a branch's step sees
# read-only and can never empty, no marker (or an old one) and no removal running: the branch's
# prepare with CI_BRANCH_PRUNE_ALL=1 DOES drop the idle caches. With a real read-only bind mount
# of main/ where the box allows one, as in a branch's pipeline. Mutant: the guard is "any trash is
# not empty" (what 39c5c37 had), or the marker's age is not looked at.
ro_main=no
for case_ in "no marker" "an old marker"; do
    r=$(attack_tree "ro-main-${case_// /-}")
    mkdir -m 0700 "$r/main/.trash"
    mkdir "$r/main/.trash/left-over"
    ro_main=no
    if [ "$(id -u)" = 0 ] && mount --bind "$r/main" "$r/main" 2>/dev/null; then
        ro_mounts+=("$r/main")
        if mount -o remount,bind,ro "$r/main" 2>/dev/null && ! test -w "$r/main"; then ro_main=yes; fi
    fi
    mk_branch "$r/branches/b-idle-00000003"
    if [ "$case_" = "an old marker" ]; then : >"$r/locks/main-trash.pending"; pending_age "$r/locks/main-trash.pending" 180; fi
    out=$(prep_all_branch "$r")
    is "main/.trash holds a leftover (main/ read-only: $ro_main), $case_: prune-all drops the idle branch cache, no W1206" "no no yes" "$([ -d "$r/branches/b-idle-00000003" ] && echo yes || echo no) $(grep -q NRV-W1206 <<<"$out" && echo yes || echo no) $(grep -q RC0 <<<"$out" && echo yes)"
    if [ "$ro_main" = yes ]; then umount "$r/main"; fi
done
[ "$ro_main" = yes ] || echo "note: no read-only bind mount here: main/.trash is a plain directory in the leftover tests (the guard does not read it either way)" >&2

# (e2-2) The SHOULD: a main step does not mount branches/, so main's guard cannot see branches/.trash.
# A layout with no branches/ directory and a fresh branches-trash.pending marker: a main prepare on
# a low box keeps main/zig and prints NRV-W1206. Mutant: the guard looks at main's own mount only.
r=$(attack_tree main-only)
rmdir "$r/branches"
ci_as touch "$r/main/zig/f"
: >"$r/locks/branches-trash.pending"
out=$(prep_low_main "$r")
is "main-only layout, a fresh branches marker: main prepare keeps main/zig, says NRV-W1206" "yes yes yes" "$([ -e "$r/main/zig/f" ] && echo yes) $(grep -q "NRV-W1206" <<<"$out" && echo yes) $(grep -q RC0 <<<"$out" && echo yes)"
# and the jepsen marker the same, though the step does not mount it. Mutant: jepsen left out of the guard.
rm -f "$r/locks/branches-trash.pending"
: >"$r/locks/jepsen-trash.pending"
out=$(prep_low_main "$r")
is "a fresh jepsen marker holds main's prune off too" "yes yes" "$([ -e "$r/main/zig/f" ] && echo yes) $(grep -q "NRV-W1206" <<<"$out" && echo yes)"

# (e2-3) A removal running on another mount (locks/branches-trash.lock held by a background flock the
# test starts) holds nothing off by itself: with a young marker the prune is held off (no wait: under
# 3 s, CI_PRUNE_WAIT=1 is the longest thing a prepare waits for), with an OLD marker, or none, it
# runs (review 6004714906: a removal that never ends must not hold the prunes off for ever). Mutant:
# the lock test put back as a second clause of ci_trash_pending.
r=$(attack_tree held)
ci_as touch "$r/main/zig/f"
: >"$r/locks/branches-trash.lock"
chmod 600 "$r/locks/branches-trash.lock"
flock -o -x "$r/locks/branches-trash.lock" sleep 30 &
trash_holder=$!
for _ in $(seq 50); do (exec 3<"$r/locks/branches-trash.lock"; flock -n 3) || break; sleep 0.1; done
: >"$r/locks/branches-trash.pending"
t0=$(date +%s.%N)
out=$(prep_low_main "$r")
t1=$(date +%s.%N)
is "a removal running and a young marker: main's prune is held off, no wait (under 3 s)" "yes yes yes yes" "$([ -e "$r/main/zig/f" ] && echo yes) $(grep -q "NRV-W1206.*less than 60 minutes ago" <<<"$out" && echo yes) $(grep -q RC0 <<<"$out" && echo yes) $(awk -v a="$t0" -v b="$t1" 'BEGIN { print (b - a < 3) ? "yes" : "no" }')"
pending_age "$r/locks/branches-trash.pending" 90
out=$(prep_low_main "$r")
is "a removal still running and an OLD marker: main's prune runs, no NRV-W1206" "no no" "$([ -e "$r/main/zig/f" ] && echo yes || echo no) $(grep -q "NRV-W1206" <<<"$out" && echo yes || echo no)"
r2=$(attack_tree held-nomark)
ci_as touch "$r2/main/zig/f"
: >"$r2/locks/branches-trash.lock"
chmod 600 "$r2/locks/branches-trash.lock"
pkill -P "$trash_holder" 2>/dev/null || true
kill "$trash_holder" 2>/dev/null || true
wait "$trash_holder" 2>/dev/null || true
flock -o -x "$r2/locks/branches-trash.lock" sleep 30 &
trash_holder=$!
for _ in $(seq 50); do (exec 3<"$r2/locks/branches-trash.lock"; flock -n 3) || break; sleep 0.1; done
out=$(prep_low_main "$r2")
is "a removal running and no marker: main's prune runs too" "no" "$([ -e "$r2/main/zig/f" ] && echo yes || echo no)"
pkill -P "$trash_holder" 2>/dev/null || true
kill "$trash_holder" 2>/dev/null || true
wait "$trash_holder" 2>/dev/null || true

# (e2-4) A marker older than CI_TRASH_PENDING_MINUTES holds nothing off (default 60; the knob moves
# it): 30 minutes old holds, 90 does not; under CI_TRASH_PENDING_MINUTES=10 the 30-minute one does
# not, under 45 the 30-minute one does. Mutant: the age is not tested (-mmin removed).
for spec in "30 - yes" "90 - no" "30 10 no" "30 45 yes" "50 - yes" "70 - no"; do
    set -- $spec
    r=$(attack_tree age-$1-$2)
    ci_as touch "$r/main/zig/f"
    : >"$r/locks/main-trash.pending"
    pending_age "$r/locks/main-trash.pending" "$1"
    knob=()
    [ "$2" = - ] || knob=(CI_TRASH_PENDING_MINUTES="$2")
    held=no
    env "${knob[@]}" bash -c '. ci/cache.sh; ci_trash_pending "$1" >/dev/null' _ "$r" && held=yes
    is "a marker $1 minutes old, CI_TRASH_PENDING_MINUTES=$2: holds off? $3" "$3" "$held"
done

# (e2-5) The marker's life. ci_trash_move writes it; a drain that finds the trash empty (or empties
# it) removes it; a drain that cannot empty it leaves it, with the age it had (nothing refreshes it,
# so a trash nobody can empty, or a job keeps filling, holds the prunes for the knob's time after
# the last move and no longer). Mutants: no unmark on an empty trash; no unmark after a removal; a
# touch on a failed drain.
r=$(attack_tree life)
: >"$r/locks/main-trash.pending"
(. ci/cache.sh; ci_trash_empty "$r/main")
is "a marker and no trash: the drain removes the marker" no "$([ -e "$r/locks/main-trash.pending" ] && echo yes || echo no)"
(. ci/cache.sh; ci_trash_ready "$r/main")
: >"$r/locks/main-trash.pending"
(. ci/cache.sh; ci_trash_empty "$r/main")
is "a marker and an empty trash: the drain removes the marker" no "$([ -e "$r/locks/main-trash.pending" ] && echo yes || echo no)"
ci_as touch "$r/main/zig/f"
(. ci/cache.sh; CI_JOB_USER=$jobuser ci_trash_move "$r/main/zig")
pending_age "$r/locks/main-trash.pending" 20
before=$(stat -c %Y "$r/locks/main-trash.pending")
# a second move into the trash leaves the marker's age alone (the first move's time is "pending
# since"; review 6004714906). Mutant: ci_trash_mark touches an existing marker.
plant dir "$r/main/zig2"
ci_as touch "$r/main/zig2/f"
(. ci/cache.sh; CI_JOB_USER=$jobuser ci_trash_move "$r/main/zig2")
is "a second move into the trash leaves the marker's mtime as it was, 20 minutes old" "$before" "$(stat -c %Y "$r/locks/main-trash.pending" 2>/dev/null)"
is "the marker is still root's, 600, after the second move" "600" "$(stat -c %a "$r/locks/main-trash.pending" 2>/dev/null)"
(PATH="$tmp/stubs/norm:$PATH"; . ci/cache.sh; ci_trash_empty "$r/main") 2>/dev/null
is "a drain that cannot empty the trash leaves the marker, its mtime unchanged" "yes $before" "$([ -e "$r/locks/main-trash.pending" ] && echo yes) $(stat -c %Y "$r/locks/main-trash.pending" 2>/dev/null)"
(. ci/cache.sh; ci_trash_empty "$r/main")
is "a drain that empties the trash removes the marker and the tree" "no yes" "$([ -e "$r/locks/main-trash.pending" ] && echo yes || echo no) $([ -z "$(ls -A "$r/main/.trash")" ] && echo yes)"
# a marker that is a link is never followed: ci_trash_mark replaces it
r=$(attack_tree marklink)
ln -s "$sf" "$r/locks/main-trash.pending"
ci_as touch "$r/main/zig/f"
(. ci/cache.sh; CI_JOB_USER=$jobuser ci_trash_move "$r/main/zig")
is "a link at the marker's name is replaced, never followed" "yes $want_state" "$([ -f "$r/locks/main-trash.pending" ] && [ ! -L "$r/locks/main-trash.pending" ] && echo yes) $(sentinel_state)"

# (e2-5b) The SHOULD of review 6004928827: a marker older than CI_TRASH_PENDING_MINUTES with the trash
# still not empty (a slow drain) must not leave the prunes unguarded after a prune's OWN move: the low-disk
# prunes (ci_main_prune; the prune-all path of ci_branch_prepare) refresh the marker after their moves.
# Old marker + non-empty trash (the stub rm cannot empty it), box low, two prepares: the first prunes
# (it may: no young marker) and re-arms, so what the job rebuilds survives the second, which says
# NRV-W1206. Mutants: ci_main_prune's CI_TRASH_REFRESH=1 removed; ci_branch_prepare's refresh=1 removed;
# ci_trash_mark ignoring CI_TRASH_REFRESH.
r=$(attack_tree refresh-main)
mkdir -m 0700 "$r/main/.trash"
mkdir "$r/main/.trash/left-over"
: >"$r/locks/main-trash.pending"
chmod 600 "$r/locks/main-trash.pending"
pending_age "$r/locks/main-trash.pending" 90
ci_as touch "$r/main/zig/f"
out=$(prep_low_main "$r")
is "old marker, trash not empty, box low: the first main prepare prunes main/zig, no W1206" "no no yes" "$([ -e "$r/main/zig/f" ] && echo yes || echo no) $(grep -q NRV-W1206 <<<"$out" && echo yes || echo no) $(grep -q RC0 <<<"$out" && echo yes)"
is "the prune's own move re-armed the marker (younger than 5 minutes, still a root-only file)" "yes 600" "$([ -n "$(find "$r/locks/main-trash.pending" -maxdepth 0 -mmin -5 2>/dev/null)" ] && echo yes) $(stat -c %a "$r/locks/main-trash.pending" 2>/dev/null)"
ci_as touch "$r/main/zig/f"
out=$(prep_low_main "$r")
is "... so main/zig, rebuilt by the job, survives the second prepare, which says NRV-W1206" "yes yes yes" "$([ -e "$r/main/zig/f" ] && echo yes) $(grep -q "NRV-W1206: not pruning main's Zig caches" <<<"$out" && echo yes) $(grep -q RC0 <<<"$out" && echo yes)"
r=$(attack_tree refresh-branch)
mkdir -m 0700 "$r/branches/.trash"
mkdir "$r/branches/.trash/left-over"
: >"$r/locks/branches-trash.pending"
chmod 600 "$r/locks/branches-trash.pending"
pending_age "$r/locks/branches-trash.pending" 90
mk_branch "$r/branches/b-idle-00000003"
out=$(prep_all_branch "$r")
is "old marker, trash not empty, prune-all: the first branch prepare drops the idle cache, no W1206" "no no yes" "$([ -d "$r/branches/b-idle-00000003" ] && echo yes || echo no) $(grep -q NRV-W1206 <<<"$out" && echo yes || echo no) $(grep -q RC0 <<<"$out" && echo yes)"
is "the prune-all's own moves re-armed the branches marker" "yes" "$([ -n "$(find "$r/locks/branches-trash.pending" -maxdepth 0 -mmin -5 2>/dev/null)" ] && echo yes)"
mk_branch "$r/branches/b-idle-00000004"
out=$(prep_all_branch "$r")
is "... so a cache made since survives the second prepare, which says NRV-W1206" "yes yes yes" "$([ -d "$r/branches/b-idle-00000004" ] && echo yes) $(grep -q "NRV-W1206: not pruning every idle branch cache" <<<"$out" && echo yes) $(grep -q RC0 <<<"$out" && echo yes)"
# Every other move leaves an old marker alone (only a prune's refreshes): a reset or a seed's move.
r=$(attack_tree norefresh)
: >"$r/locks/main-trash.pending"
pending_age "$r/locks/main-trash.pending" 90
ci_as touch "$r/main/zig/f"
(. ci/cache.sh; CI_JOB_USER=$jobuser ci_trash_move "$r/main/zig")
is "a move that is not a low-disk prune's leaves an old marker old" "yes" "$([ -z "$(find "$r/locks/main-trash.pending" -maxdepth 0 -mmin -5 2>/dev/null)" ] && echo yes)"
# A CI_TRASH_REFRESH preset in the environment (a pipeline variable, a shell's export) is dropped when
# cache.sh is sourced: it would make every plain move refresh the marker (review 6005098936).
# Mutant: the `unset CI_TRASH_REFRESH` line removed.
r=$(attack_tree preset-refresh)
: >"$r/locks/main-trash.pending"
pending_age "$r/locks/main-trash.pending" 90
ci_as touch "$r/main/zig/f"
(export CI_TRASH_REFRESH=1; . ci/cache.sh; CI_JOB_USER=$jobuser ci_trash_move "$r/main/zig")
is "a CI_TRASH_REFRESH=1 preset in the environment does not refresh an old marker on a plain move" "yes" "$([ -z "$(find "$r/locks/main-trash.pending" -maxdepth 0 -mmin -5 2>/dev/null)" ] && echo yes)"
# The prune-all's guard is tested under the branches' lock (fd 7), not before the wait for it (review
# 6005098936): a stub flock writes a young marker (5 minutes old) just as the step waits for fd 7, which
# is what a step that came first leaves. The step then neither drops the idle cache nor refreshes the
# marker. Mutant: the test made before the lock again (a marker that appears after it is not seen).
mkdir -p "$tmp/stubs/race"
chmod 755 "$tmp/stubs/race"
real_flock=$(command -v flock)
cat >"$tmp/stubs/race/flock" <<EOS
#!/bin/sh
case "\$*" in
    "-x -w "*" 7") if [ ! -e "\$RACE_MARKER" ]; then : >"\$RACE_MARKER"; chmod 600 "\$RACE_MARKER"; touch -d "5 minutes ago" "\$RACE_MARKER"; fi ;;
esac
exec $real_flock "\$@"
EOS
chmod 755 "$tmp/stubs/race/flock"
r=$(attack_tree race-prune-all)
mk_branch "$r/branches/b-idle-00000003"
race_before=$(date -d "5 minutes ago" +%s)
out=$(PATH="$tmp/stubs/race:$tmp/stubs/norm:$PATH" RACE_MARKER="$r/locks/branches-trash.pending" CI_BRANCH_PRUNE_ALL=1 bash -c '. ci/cache.sh; CI_JOB_USER=$1 CI_LOCK_WAIT=2 ci_branch_prepare "$2" feature/atk 2>&1 && echo RC0' _ "$jobuser" "$r" || true)
race_mtime=$(stat -c %Y "$r/locks/branches-trash.pending" 2>/dev/null || echo 0)
is "a young marker that appears while the step waits for the lock: no prune-all, NRV-W1206, the prepare goes on" "yes yes yes" "$([ -d "$r/branches/b-idle-00000003" ] && echo yes) $(grep -q "NRV-W1206: not pruning every idle branch cache" <<<"$out" && echo yes) $(grep -q RC0 <<<"$out" && echo yes)"
is "... and the marker is not refreshed (its mtime is still 5 minutes ago, give or take)" "yes" "$([ "$race_mtime" -le $((race_before + 30)) ] && [ "$race_mtime" -ge $((race_before - 30)) ] && echo yes)"

# (e2-5c) The NIT of review 6004928827, the lost-marker race: moves run under the main, key and Jepsen
# locks, not the trash lock, so one can land after a drain's "empty" test and before its unmark. The
# unmark now removes the marker and then looks at the trash again, writing a fresh one if it is not
# empty. Functional (a trash with a tree, then without), and with the race itself: a stub rm that, as it
# removes the marker, puts a tree in the trash (what the move's rename does at that instant).
# Mutant: ci_trash_unmark is the bare rm -f again.
r=$(attack_tree recheck)
(. ci/cache.sh; ci_trash_ready "$r/main")
mkdir "$r/main/.trash/landed"
: >"$r/locks/main-trash.pending"
pending_age "$r/locks/main-trash.pending" 90
(. ci/cache.sh; ci_trash_unmark "$r/main")
is "unmark with a tree in the trash: a fresh marker (not the 90-minute-old one) is there" "yes" "$([ -n "$(find "$r/locks/main-trash.pending" -maxdepth 0 -mmin -5 2>/dev/null)" ] && echo yes)"
rmdir "$r/main/.trash/landed"
(. ci/cache.sh; ci_trash_unmark "$r/main")
is "unmark with an empty trash: no marker" "no" "$([ -e "$r/locks/main-trash.pending" ] && echo yes || echo no)"
mkdir -p "$tmp/stubs/race"
realrm=$(command -v rm)
printf '#!/bin/sh\nfor a; do case "$a" in *-trash.pending) mkdir -p "$RACE_DIR/landed" ;; esac; done\nexec %s "$@"\n' "$realrm" >"$tmp/stubs/race/rm"
chmod 755 "$tmp/stubs/race/rm"
r=$(attack_tree race)
(. ci/cache.sh; ci_trash_ready "$r/main")
: >"$r/locks/main-trash.pending"
(PATH="$tmp/stubs/race:$PATH" RACE_DIR="$r/main/.trash" bash -c '. ci/cache.sh; ci_trash_empty "$1"' _ "$r/main")
is "a move that lands as the drain unmarks an empty trash: the trash has a tree and a marker" "yes yes" "$([ -d "$r/main/.trash/landed" ] && echo yes) $([ -e "$r/locks/main-trash.pending" ] && echo yes)"

# (e2-6) Jepsen's trash: the step that swept it empties it in its tail, with the tail bound
# (ci_step_finish with the job), and no other step does. Mutant: `jepsen` not added to the tail's mounts.
r=$(attack_tree jep)
mkdir -m 0755 "$r/jepsen"
plant dir "$r/jepsen/20240101T000000Z-1"
(. ci/cache.sh; CI_JOB_USER=$jobuser ci_trash_move "$r/jepsen/20240101T000000Z-1")
is "the sweep's move into jepsen/.trash wrote jepsen's marker" yes "$([ -e "$r/locks/jepsen-trash.pending" ] && echo yes)"
(. ci/cache.sh; ci_step_finish branch "$r" "")
is "a branch tail of another job leaves jepsen's trash alone" "yes" "$([ -n "$(ls -A "$r/jepsen/.trash")" ] && echo yes)"
(. ci/cache.sh; ci_step_finish branch "$r" "" jepsen)
is "the jepsen step's tail empties jepsen's trash and its marker" "yes no" "$([ -z "$(ls -A "$r/jepsen/.trash")" ] && echo yes) $([ -e "$r/locks/jepsen-trash.pending" ] && echo yes || echo no)"
# The Jepsen step drains jepsen/.trash right after the sweep, while fd 8 is held, bounded by
# CI_TRASH_SECONDS (the default: no secs argument), so that its marker does not hold the box-wide
# prunes off for a whole Jepsen run (review 6004714906). Mutant: the drain line removed.
sweep_l=$(grep -n '^    ci_jepsen_sweep "\$cache/jepsen"$' "$ws" | cut -d: -f1)
jdrain_l=$(grep -n '^    ci_trash_empty "\$cache/jepsen"$' "$ws" | cut -d: -f1 | head -n 1)
jdrain2_l=$(grep -n '^    ci_trash_empty "\$cache/jepsen"$' "$ws" | cut -d: -f1 | tail -n 1)
tools_l=$(grep -n '^    ci_child_ensure "\$cache/jepsen/tools" "\$cache/jepsen" || exit 1$' "$ws" | cut -d: -f1)
unlock_l=$(grep -n '^    flock -u 8 2>/dev/null || true$' "$ws" | cut -d: -f1)
is "the jepsen step drains jepsen/.trash after the sweep and before it lets fd 8 go (static)" yes "$([ -n "$sweep_l" ] && [ -n "$jdrain_l" ] && [ -n "$unlock_l" ] && [ "$sweep_l" -lt "$jdrain_l" ] && [ "$jdrain_l" -lt "$unlock_l" ] && echo yes)"
# ... and again after the reset of jepsen/tools, which can move the old one into jepsen/.trash and
# write its marker (review 6004928827). Mutant: that second drain removed.
is "the jepsen step drains jepsen/.trash again right after the tools reset, before fd 8 is let go (static)" yes "$([ -n "$tools_l" ] && [ -n "$jdrain2_l" ] && [ "$jdrain_l" -ne "$jdrain2_l" ] && [ "$tools_l" -lt "$jdrain2_l" ] && [ "$jdrain2_l" -lt "$unlock_l" ] && echo yes)"
# The exception to "root never walks a job's tree under a lock others wait on" is recorded where the rule is written.
is "the Jepsen drain under fd 8 is recorded as a deliberate exception in cache.sh, the step and ops/ci/README.md" "1 1 1" "$(grep -c 'ONE DELIBERATE EXCEPTION' ci/cache.sh || true) $(grep -c 'A DELIBERATE EXCEPTION' "$ws" || true) $(grep -c -F '**One deliberate' ops/ci/README.md || true)"
r=$(attack_tree jep2)
mkdir -m 0755 "$r/jepsen"
plant dir "$r/jepsen/20240101T000000Z-1"
touch -d '20 days ago' "$r/jepsen/20240101T000000Z-1"
(. ci/cache.sh; ci_jepsen_sweep "$r/jepsen"; ci_trash_empty "$r/jepsen")
is "sweep then drain: jepsen's trash and marker are gone at once" "yes no" "$([ -z "$(ls -A "$r/jepsen/.trash")" ] && echo yes) $([ -e "$r/locks/jepsen-trash.pending" ] && echo yes || echo no)"

# (e2-7) The tail against Woodpecker's timeout: ci_tail_seconds is CI_TRASH_TAIL_SECONDS, capped to
# the time left before CI_REPO_TIMEOUT_MINUTES (default 360) minus 120 s from CI_STEP_START; no start
# time, no cap. With no time left the tail does not empty and says so. Mutant: no cap.
now=$(date +%s)
tails() { env "$@" bash -c '. ci/cache.sh; ci_tail_seconds'; }
is "ci_tail_seconds: no CI_STEP_START, no cap" 300 "$(tails CI_TRASH_TAIL_SECONDS=300)"
is "ci_tail_seconds: a step that began a minute ago, 360 minutes: the whole 300" 300 "$(tails CI_STEP_START=$((now - 60)))"
left=$(tails CI_STEP_START=$((now - 21600 + 200)))
is "ci_tail_seconds: 200 s before the limit leaves 200 - 120 = 80 s (give or take a second)" yes "$([ "$left" -ge 78 ] && [ "$left" -le 80 ] && echo yes)"
left=$(tails CI_STEP_START=$((now - 21600 + 600)) CI_TRASH_TAIL_SECONDS=60)
is "ci_tail_seconds: a tail of 60 s with plenty of time is 60" 60 "$left"
left=$(tails CI_STEP_START=$((now - 540)) CI_REPO_TIMEOUT_MINUTES=10)
is "ci_tail_seconds: past the limit minus the margin is 0 or less" yes "$([ "$left" -le 0 ] && echo yes)"
r=$(attack_tree tail-cap)
ci_as touch "$r/main/zig/f"
(. ci/cache.sh; CI_JOB_USER=$jobuser ci_trash_move "$r/main/zig")
out=$( (. ci/cache.sh; CI_STEP_START=$((now - 540)) CI_REPO_TIMEOUT_MINUTES=10 ci_step_finish main "$r" "") 2>&1)
is "no time left before the repository's timeout: the tail leaves the trash and says why" "yes yes" "$([ -n "$(ls -A "$r/main/.trash")" ] && echo yes) $(grep -q "close to the repository's timeout" <<<"$out" && echo yes)"
(. ci/cache.sh; CI_STEP_START=$((now - 60)) CI_REPO_TIMEOUT_MINUTES=10 ci_step_finish main "$r" "")
is "with time left the tail empties the trash" "" "$(ls -A "$r/main/.trash")"
# (e2-8) The job's own bound against Woodpecker's timeout (ci_job_seconds; NRV-W1207, review
# 6004714906): no CI_STEP_START, or time to spare, is MINUTES * 60 and silent; a step that has used
# 40 minutes of 60 with a 300 s tail leaves 60 - 40 - 2 - 5 = about 13 minutes of a 330-minute ask,
# with the warning; no time at all keeps 60 s. Mutant: ci_job_seconds echoes MINUTES * 60 always.
jobs_() { env "$@" bash -c '. ci/cache.sh; ci_job_seconds "$1" "${RES:-0}" "${JOBNAME:-demo}"' _ "${JOBMIN:-330}" 2>"$tmp/jobs.err"; }
is "ci_job_seconds: no CI_STEP_START is the full 330 minutes, silent" "19800 yes" "$(jobs_ CI_X=1) $([ ! -s "$tmp/jobs.err" ] && echo yes)"
is "ci_job_seconds: a step 60 s old, default 360 minutes: the full 330 minutes, silent" "19800 yes" "$(jobs_ CI_STEP_START=$((now - 60))) $([ ! -s "$tmp/jobs.err" ] && echo yes)"
left=$(jobs_ CI_STEP_START=$((now - 2400)) CI_REPO_TIMEOUT_MINUTES=60)
is "ci_job_seconds: 40 of 60 minutes used: 20 min - 120 s - 300 s - 60 s kill-after = 720 s (give or take a few)" yes "$([ "$left" -ge 715 ] && [ "$left" -le 720 ] && echo yes)"
is "ci_job_seconds: shortened, it says NRV-W1207 with the minutes" yes "$(grep -q "NRV-W1207: the job's limit is 1[12] minutes, not the 330 asked for" "$tmp/jobs.err" && echo yes)"
# The kill-after (CI_KILL_AFTER, default 60, a whole number else 60) is in the formula (review
# 6004928827). Mutant: the kill-after left out.
left=$(jobs_ CI_STEP_START=$((now - 2400)) CI_REPO_TIMEOUT_MINUTES=60 CI_KILL_AFTER=600)
is "ci_job_seconds: CI_KILL_AFTER=600 comes off the bound: 3600 - 2400 - 120 - 300 - 600 = 180 s" yes "$([ "$left" -ge 175 ] && [ "$left" -le 180 ] && echo yes)"
# A CI_KILL_AFTER that is not a whole number is refused (NRV-E1208) before any arithmetic: nothing is
# printed and the status is 1 (review 6005098936). Mutant: CI_KILL_AFTER left out of ci_knobs_check.
for bad in soon 0 08 5m 1234567 -3; do
    left_rc=0
    left=$(jobs_ CI_STEP_START=$((now - 2400)) CI_REPO_TIMEOUT_MINUTES=60 CI_KILL_AFTER=$bad) || left_rc=$?
    is "ci_job_seconds: CI_KILL_AFTER='$bad' is refused with NRV-E1208 and prints no bound" "1  yes" "$left_rc $left $(grep -q "NRV-E1208: CI_KILL_AFTER='$bad'" "$tmp/jobs.err" && echo yes)"
done
# The root tests' bound (what check-scripts runs first) comes off the job's: 3600 - 300 - 120 - 300 -
# 60 - (1200 + 60) = 1560 s of the 75 minutes asked for. Mutant: RESERVED ignored.
left=$(RES=1260 JOBMIN=75 jobs_ CI_STEP_START=$((now - 300)) CI_REPO_TIMEOUT_MINUTES=60)
is "ci_job_seconds: the reserved seconds (the root tests' bound and kill-after) come off the job's bound" yes "$([ "$left" -ge 1555 ] && [ "$left" -le 1560 ] && echo yes)"
is "ci_job_seconds: ... with NRV-W1207 (26 minutes of the 75)" yes "$(grep -q "NRV-W1207: the job's limit is 2[56] minutes, not the 75 asked for" "$tmp/jobs.err" && echo yes)"
left=$(RES=1260 JOBMIN=75 jobs_ CI_STEP_START=$((now - 300)))
is "ci_job_seconds: the same reserve against the default 360 minutes changes nothing: 4500 s, silent" "4500 yes" "$left $([ ! -s "$tmp/jobs.err" ] && echo yes)"
# With no time left (under 60 s) the job is not started: 0, and NRV-E1215 says so, naming the
# Timeout, never CI_STEP_MINUTES as the way out. Mutant: the old floor (60 s kept) is back.
is "ci_job_seconds: a step past the limit: 0, the job is not started" "0" "$(jobs_ CI_STEP_START=$((now - 4000)) CI_REPO_TIMEOUT_MINUTES=60)"
is "ci_job_seconds: ... with NRV-E1215 naming the job and the Timeout, not CI_STEP_MINUTES as the fix" "yes no" "$(grep -q "NRV-E1215: demo was not started: .*raise the repository's Timeout" "$tmp/jobs.err" && echo yes) $(grep -q "CI_STEP_MINUTES raises" "$tmp/jobs.err" && echo yes || echo no)"
is "ci_job_seconds: 20 s left (under the 60 s floor) is 0 too" "0" "$(jobs_ CI_STEP_START=$((now - 3100)) CI_REPO_TIMEOUT_MINUTES=60)"
is "ci_job_seconds: no time left once the reserve is taken: 0" "0" "$(RES=1260 JOBMIN=75 jobs_ CI_STEP_START=$((now - 2400)) CI_REPO_TIMEOUT_MINUTES=60)"
is "ci_job_seconds: a job that fits is left alone, silent (75 of 360, 10 min used)" "4500 yes" "$(JOBMIN=75 jobs_ CI_STEP_START=$((now - 600))) $([ ! -s "$tmp/jobs.err" ] && echo yes)"
is "the step bounds the job with ci_step_job, with the root tests' reserve (and the validated kill-after) for check-scripts (static)" "1 1" "$(grep -c '^ci_step_job "\$job" "\$minutes" "\$reserved" "\$((test_minutes \* 60))" tests_cmd job_cmd || status=\$?$' "$ws" || true) $(grep -c '^if \[ "\$job" = check-scripts \]; then reserved=\$((test_minutes \* 60 + \${CI_KILL_AFTER:-60})); fi$' "$ws" || true)"
# The step's tail follows the job whatever its status: no `exit` between the ci_step_job call and ci_step_finish.
job_l=$(grep -n '^ci_step_job ' "$ws" | cut -d: -f1)
fin_l=$(grep -n '^ci_step_finish ' "$ws" | cut -d: -f1)
is "no exit between the step's job and its tail (static)" "0" "$(sed -n "${job_l},${fin_l}p" "$ws" | grep -c '^[[:space:]]*exit' || true)"
# --- BEGIN ci_step_job (behavioural; the mutation harness extracts this block)
# ci_step_job (ci/cache.sh) is what the step calls: a bash function named timeout stands in for
# timeout(1), logs what it was asked to run and moves $SECONDS on by the limit, as a job that ran
# past it would (ci_run_timed then says NRV-E1215), so nothing sleeps. Cases: no time left (status 1,
# neither the root tests nor the job started, no CI_TIMEOUT_KNOB); a shortened job (its E1215 names
# the repository's Timeout, not CI_STEP_MINUTES); a job that fits (names CI_STEP_MINUTES, the knob
# unset); check-scripts (the tests first, with their own bound, then the job). Mutants: the job run
# anyway when no time is left; CI_TIMEOUT_KNOB exported unconditionally; the old E1215 wording.
sj_run() { # sj_run JOB MINUTES RESERVED [VAR=value...]: sets sj_rc, sj_log, sj_err, sj_knob
    local job="$1" min="$2" res="$3"
    shift 3
    rm -f "$tmp/sj.log" "$tmp/sj.knob"
    sj_rc=0
    (
        . ci/cache.sh
        export CI_KILL_AFTER=1 CI_TRASH_TAIL_SECONDS=300
        for kv in "$@"; do export "${kv?}"; done
        unset CI_TIMEOUT_KNOB
        timeout() { # timeout --kill-after=Ns SECONDS CMD...
            echo "$1 $2 ${3##*/}" >>"$tmp/sj.log"
            SECONDS=$((SECONDS + $2))
            return 124
        }
        # shellcheck disable=SC2034 # namerefs, read by ci_step_run_with_tests
        tests_cmd=(ci/ci_test.sh)
        # shellcheck disable=SC2034 # namerefs, read by ci_step_run_with_tests
        job_cmd=(ci/job.sh "$job")
        sj_status=0
        ci_step_job "$job" "$min" "$res" 1200 tests_cmd job_cmd || sj_status=$?
        echo "knob=${CI_TIMEOUT_KNOB-unset}" >"$tmp/sj.knob"
        exit "$sj_status"
    ) 2>"$tmp/sj.err" || sj_rc=$?
    sj_log=$(if [ -f "$tmp/sj.log" ]; then tr '\n' '|' <"$tmp/sj.log"; fi)
    sj_err=$(cat "$tmp/sj.err")
    sj_knob=$(if [ -f "$tmp/sj.knob" ]; then cat "$tmp/sj.knob"; fi)
}
now=$(date +%s)
sj_run check 5 0 CI_STEP_START=$((now - 4000)) CI_REPO_TIMEOUT_MINUTES=60
is "ci_step_job: no time left: status 1, the job was not run, no CI_TIMEOUT_KNOB" "1||knob=unset" "$sj_rc|$sj_log|$sj_knob"
is "... NRV-E1215 says it was not started and names the Timeout" "yes no" "$(grep -q "NRV-E1215: check was not started: .*raise the repository's Timeout (Woodpecker repository settings; ops/ci/README.md), with CI_REPO_TIMEOUT_MINUTES to match; CI_STEP_MINUTES does not help" <<<"$sj_err" && echo yes) $(grep -q "raises it for a run" <<<"$sj_err" && echo yes || echo no)"
sj_run check-scripts 75 1260 CI_STEP_START=$((now - 2400)) CI_REPO_TIMEOUT_MINUTES=60
is "ci_step_job: check-scripts with the reserve eating the rest: neither the root tests nor the job ran, status 1" "1||knob=unset" "$sj_rc|$sj_log|$sj_knob"
sj_run check 330 0 CI_STEP_START=$((now - 2400)) CI_REPO_TIMEOUT_MINUTES=60
is "ci_step_job: a shortened job runs once, with the shortened bound and the validated kill-after, and times out (124)" "124 yes" "$sj_rc $(grep -Eq '^--kill-after=1s 7[4-9][0-9] job.sh\|$' <<<"$sj_log" && echo yes)"
is "... the job's NRV-E1215 names the repository's Timeout, not CI_STEP_MINUTES (the knob's text, with NRV-W1207)" "yes no" "$(grep -Eq "NRV-E1215: check ran past its [0-9]+ (seconds|minutes) and was stopped: a hung job, or a limit too short for this box; raise the repository's Timeout \(Woodpecker repository settings\), with CI_REPO_TIMEOUT_MINUTES to match; the job was shortened \(NRV-W1207\), so CI_STEP_MINUTES does not help$" <<<"$sj_err" && echo yes) $(grep -q "CI_STEP_MINUTES raises it" <<<"$sj_err" && echo yes || echo no)"
sj_run check 5 0 CI_X=1
is "ci_step_job: a job that fits runs with its full bound (300 s), CI_TIMEOUT_KNOB stays unset" "124 yes knob=unset" "$sj_rc $(grep -q '^--kill-after=1s 300 job.sh|$' <<<"$sj_log" && echo yes) $sj_knob"
is "... its NRV-E1215 names CI_STEP_MINUTES" "yes no" "$(grep -q "NRV-E1215: check ran past its 5 minutes and was stopped: a hung job, or a limit too short for this box; CI_STEP_MINUTES raises it for a run$" <<<"$sj_err" && echo yes) $(grep -q "repository's Timeout" <<<"$sj_err" && echo yes || echo no)"
sj_run check-scripts 5 1260 CI_X=1
is "ci_step_job: check-scripts runs the root tests first, bounded by their own 1200 s, then the job" "yes yes" "$(grep -q '^--kill-after=1s 1200 ci_test.sh|--kill-after=1s 300 job.sh|$' <<<"$sj_log" && echo yes) $(grep -q "CI_SCRIPTS_TEST_MINUTES raises it for a run" <<<"$sj_err" && echo yes)"
# --- END ci_step_job
is "NRV-W1207 is registered in docs/ERRORS.md" 1 "$(grep -c '^| NRV-W1207 |' docs/ERRORS.md || true)"
# The step drains the trash of the mount it writes BEFORE it measures "low" (static: the drain is
# above the disk test), and passes its start time, and the guard is registered. Mutant: the drain moved below.
drain_l=$(grep -n '^if \[ "\$role" = main \]; then ci_trash_empty "\$cache/main"; else ci_trash_empty "\$cache/branches"; fi$' "$ws" | cut -d: -f1)
low_l=$(grep -n '^if ci_disk_low "\$cache_fs" "\$free_min_gib"; then low=yes; fi$' "$ws" | cut -d: -f1)
is "the step empties its mount's trash before it measures low (static)" yes "$([ -n "$drain_l" ] && [ -n "$low_l" ] && [ "$drain_l" -lt "$low_l" ] && echo yes)"
is "the step records when it began, for the tail's cap (static)" 1 "$(grep -c '^CI_STEP_START=\$(date +%s)$' "$ws" || true)"
is "NRV-W1206 is registered in docs/ERRORS.md" 1 "$(grep -c '^| NRV-W1206 |' docs/ERRORS.md || true)"

# (f) The knobs are validated as the others are (NRV-E1208): a whole number, 1 or more.
for knob in CI_BRANCH_DU_SECONDS CI_TRASH_SECONDS CI_TRASH_TAIL_SECONDS CI_TRASH_PENDING_MINUTES CI_REPO_TIMEOUT_MINUTES CI_KILL_AFTER CI_MIN_FREE_INODES; do
    for bad in 0 abc '1;touch x' -5 1.5 ' 3' 9999999 08 5m; do
        refuses NRV-E1208 "$knob='$bad'" env "$knob=$bad" bash -c '. ci/cache.sh; ci_knobs_check'
    done
    ok "$knob=1 and 999999 are accepted" env "$knob=999999" bash -c '. ci/cache.sh; ci_knobs_check'
done
r=$(attack_tree knobs2)
refuses NRV-E1208 "ci_branch_prepare with CI_BRANCH_DU_SECONDS=0" env CI_BRANCH_DU_SECONDS=0 CI_JOB_USER="$jobuser" bash -c '. ci/cache.sh; ci_branch_prepare "$1" feature/atk' _ "$r"
is "a refused knob made no branch directory" no "$([ -e "$r/branches/$branch_key" ] && echo yes || echo no)"

# (g) NRV-E1236: a trash that is not root's alone (a link, a file, a mode others can use, another
# owner, an ACL, another file system) is refused and nothing is moved, whichever lock the caller
# holds; the sentinel a link points at is left alone.
trash_case() { # trash_case NAME: a fresh tree whose zig has a file; sets r and t
    r=$(attack_tree trash-$1)
    ci_as touch "$r/main/zig/f"
    t="$r/main/.trash"
}
trash_refused() { # trash_refused NAME: ci_trash_move of zig is E1236, and zig is still there
    local out rc=0
    out=$( (. ci/cache.sh; CI_JOB_USER=$jobuser ci_trash_move "$r/main/zig") 2>&1) || rc=$?
    is "E1236: $1: refused, nothing moved" "1 yes yes" "$rc $(grep -q NRV-E1236 <<<"$out" && echo yes) $([ -e "$r/main/zig/f" ] && echo yes)"
}
trash_case link
ln -s "$sd" "$t"
trash_refused "a link"
is "E1236: the link's target is left alone" "$want_state" "$(sentinel_state)"
trash_case file
: >"$t"
trash_refused "a file"
trash_case mode
mkdir -m 0755 "$t"
trash_refused "mode 0755"
trash_case mode2
mkdir -m 0700 "$t"
chmod 0710 "$t"
trash_refused "mode 0710"
if [ "$(id -u)" = 0 ]; then
    trash_case owner
    mkdir -m 0700 "$t"
    chown "$jobuser" "$t"
    trash_refused "owned by the job's user"
    if command -v setfacl >/dev/null; then
        trash_case acl
        mkdir -m 0700 "$t"
        if setfacl -m "u:$jobuser:---" "$t" 2>/dev/null && ci_has_acl_probe=$(. ci/cache.sh; ci_has_acl "$t" && echo yes) && [ "$ci_has_acl_probe" = yes ]; then
            is "E1236 (acl): the mode alone would pass" "" "$(find "$t" -maxdepth 0 -perm /077)"
            trash_refused "a mode 0700 directory with an ACL"
        else
            echo "note: this file system takes no ACLs: the trash ACL test was skipped" >&2
        fi
    fi
    # Another file system: the trash is a mount (or the tree to move is): never moved, never copied.
    trash_case dev
    mkdir -m 0700 "$t"
    if mount -t tmpfs tmpfs "$t" 2>/dev/null; then
        ro_mounts+=("$t")
        chmod 0700 "$t"
        trash_refused "a trash on another file system"
        umount "$t"
        trash_case dev2
        if mount -t tmpfs tmpfs "$r/main/zig" 2>/dev/null; then
            ro_mounts+=("$r/main/zig")
            ci_as touch "$r/main/zig/f" 2>/dev/null || : >"$r/main/zig/f"
            rc=0
            (. ci/cache.sh; CI_JOB_USER=$jobuser ci_trash_move "$r/main/zig") >/dev/null 2>&1 || rc=$?
            is "a tree on another file system is not moved (mv would copy it)" "1 yes" "$rc $([ -e "$r/main/zig/f" ] && echo yes)"
            umount "$r/main/zig"
        else
            echo "note: no tmpfs mount here: the other-file-system tree test was skipped" >&2
        fi
    else
        echo "note: no tmpfs mount here: the other-file-system tests were skipped" >&2
    fi
else
    skip_note "the trash's owner, ACL and file-system tests"
fi
# And the callers say so, once, and go on: the prune of a mount root and a branch's prune.
trash_case prune
mkdir -m 0755 "$t"
out=$(CI_PRUNE_WAIT=1 bash -c '. ci/cache.sh; ci_main_lock_open "$1" && ci_main_prune "$1" 0' _ "$r" 2>&1 | head -5; true)
r=$(attack_tree trash-bp)
mkdir -m 0755 "$r/branches/.trash"
plant dir "$r/branches/b-old-00000002"
touch -d "20 days ago" "$r/branches/b-old-00000002"
out=$(prep_b "$r")
is "E1236 in a branch's prune: once, the step goes on (RC0), nothing was dropped" "1 yes yes" "$(grep -c NRV-E1236 <<<"$out") $(grep -q RC0 <<<"$out" && echo yes) $([ -e "$r/branches/b-old-00000002" ] && echo yes)"
# A concurrent step's trash empty removing the empty box between the mktemp and the mv: tried again.
trash_case retry
slow_reset
rc=0
(. ci/cache.sh; PATH="$mkmv_dir:$PATH" CI_JOB_USER=$jobuser ci_trash_move "$r/main/zig") >/dev/null 2>&1 || rc=$?
is "a box removed under the move: the move is tried again and succeeds" "0 no yes" "$rc $([ -e "$r/main/zig" ] && echo yes || echo no) $([ -e "$mark/mk-once" ] && echo yes)"

# (h) NRV-W1205: a trash that cannot be emptied (an rm that fails, as a mount inside it would) is
# a warning, not a refusal, and the next call removes what is left. A job that still has its
# working directory in a moved tree and keeps writing there does not stall it: the removal is
# bounded (CI_TRASH_SECONDS, one deadline) and the next call, once the job stops, empties it.
mkdir -p "$tmp/stubs/badrm"
chmod 755 "$tmp/stubs/badrm"
printf '#!/bin/sh\nexit 1\n' >"$tmp/stubs/badrm/rm"
chmod 755 "$tmp/stubs/badrm/rm"
trash_case w1205
(. ci/cache.sh; CI_JOB_USER=$jobuser ci_trash_move "$r/main/zig") >/dev/null 2>&1
out=$( (. ci/cache.sh; PATH="$tmp/stubs/badrm:$PATH" ci_trash_empty "$r/main") 2>&1)
is "W1205: a trash that cannot be emptied is a warning, and the tree is still there" "yes yes" "$(grep -q NRV-W1205 <<<"$out" && echo yes) $([ -n "$(ls -A "$r/main/.trash")" ] && echo yes)"
out=$( (. ci/cache.sh; ci_trash_empty "$r/main") 2>&1)
is "the next call empties it, silently" " " "$(ls -A "$r/main/.trash") $out"
trash_case cwd
ci_as mkdir -p "$r/main/zig/o"
writer_flag="$tmp/writer-flag"
: >"$writer_flag"
chmod 644 "$writer_flag"
ci_as sh -c 'cd "$1/o" && i=0 && while [ -e "$2" ]; do : >"f$i" 2>/dev/null; i=$((i + 1)); done' _ "$r/main/zig" "$writer_flag" 2>/dev/null &
writer=$!
sleep 0.5
(. ci/cache.sh; CI_JOB_USER=$jobuser ci_trash_move "$r/main/zig") >/dev/null 2>&1
t0=$(now)
out=$( (. ci/cache.sh; CI_TRASH_SECONDS=2 ci_trash_empty "$r/main") 2>&1)
t1=$(now)
is "a job writing in a moved tree: the empty ends in a bounded time (CI_TRASH_SECONDS=2, under 10 s)" yes "$(awk -v a="$t0" -v b="$t1" 'BEGIN { print (b - a < 10) ? "yes" : "no" }')"
rm -f "$writer_flag"
wait "$writer" 2>/dev/null || true
out=$( (. ci/cache.sh; ci_trash_empty "$r/main") 2>&1)
is "and once the job has stopped the next call empties the trash" "" "$(ls -A "$r/main/.trash")"

# (i) The size a step records is bounded: a du that runs past CI_BRANCH_DU_SECONDS counts as over
# every bound (999999), and the next step starts that cache again; a record that is not a number is 0;
# and the prune reads the records instead of walking the other branches' trees.
mkstub du2 "$real_du" "echo \"\$*\" >>\"$mark/du.log\"; case \"\$*\" in *slowtree*) sleep 5 ;; esac"
mv "$tmp/stubs/du2/du2" "$tmp/stubs/du2/du"
r=$(attack_tree size)
mkdir -p "$r/branches/slowtree"
chown "$jobuser" "$r/branches/slowtree"
t0=$(now)
got=$( (. ci/cache.sh; PATH="$tmp/stubs/du2:$PATH" CI_BRANCH_DU_SECONDS=1 ci_dir_gib "$r/branches/slowtree"))
t1=$(now)
is "a du past CI_BRANCH_DU_SECONDS counts as over every bound, and ends in time" "999999 yes" "$got $(awk -v a="$t0" -v b="$t1" 'BEGIN { print (b - a < 4) ? "yes" : "no" }')"
(. ci/cache.sh; PATH="$tmp/stubs/du2:$PATH" CI_BRANCH_DU_SECONDS=1 ci_branch_measure "$r/locks" bk "$r/branches/slowtree")
is "the record of a timed-out walk is 999999" "999999" "$(. ci/cache.sh; ci_branch_size "$r/locks" bk)"
echo abc >"$r/locks/bk.size"
is "a record that is not a number is 0" "0" "$(. ci/cache.sh; ci_branch_size "$r/locks" bk)"
is "no record is 0" "0" "$(. ci/cache.sh; ci_branch_size "$r/locks" none)"
r=$(attack_tree size2)
mk_branch "$r/branches/$branch_key"
ci_as touch "$r/branches/$branch_key/zig/marker"
echo 999999 >"$r/locks/$branch_key.size"
plant dir "$r/branches/b-other-00000009"
echo 0 >"$r/locks/b-other-00000009.size"
slow_reset
rm -f "$mark/du.log"
out=$( (. ci/cache.sh; PATH="$tmp/stubs/du2:$PATH" CI_JOB_USER=$jobuser CI_LOCK_WAIT=2 ci_branch_prepare "$r" feature/atk 2>&1 && echo RC0) || true)
is "an own cache recorded over the bound is started again (and the step goes on)" "yes no" "$(grep -q RC0 <<<"$out" && echo yes) $([ -e "$r/branches/$branch_key/zig/marker" ] && echo yes || echo no)"
is "the prune walked no other branch's tree (du saw only this step's own directory)" "0" "$(grep -c b-other "$mark/du.log" || true)"
is "the step recorded its own size again (a started directory: 1 GiB, rounded up)" "1" "$(cat "$r/locks/$branch_key.size")"
# A seed that cannot be moved into place is moved aside, not removed under the branches' lock.
mkstub mv "$(command -v mv)" "case \"\$*\" in *.partial.*) case \"\$*\" in *.trash*) ;; *) exit 1 ;; esac ;; esac"
mkstub rmlog "$real_rm" "case \"\$*\" in *.partial.*) echo \"\$*\" >>\"$mark/rm.log\" ;; esac"
mkdir -p "$tmp/stubs/both"
chmod 755 "$tmp/stubs/both"
cp "$tmp/stubs/mv/mv" "$tmp/stubs/rmlog/rmlog" "$tmp/stubs/both/"
mv "$tmp/stubs/both/rmlog" "$tmp/stubs/both/rm"
r=$(attack_tree seedmv)
ci_as mkdir -p "$r/main/zig/p/pkg"
ci_as touch "$r/main/zig/p/pkg/f"
slow_reset
out=$( (. ci/cache.sh; PATH="$tmp/stubs/both:$PATH" CI_JOB_USER=$jobuser CI_LOCK_WAIT=2 ci_branch_prepare "$r" feature/atk 2>&1 && echo RC0) || true)
is "a seed that could not be moved into place: no rm of the partial directory, none left, the trash empty" "yes 0 yes" "$(grep -q NRV-E1214 <<<"$out" && echo yes) $(find "$r/branches" -maxdepth 1 -name '*.partial.*' | wc -l) $([ -z "$(ls -A "$r/branches/.trash")" ] && [ ! -e "$mark/rm.log" ] && echo yes)"

# (j) A trash whose removal outlasts CI_TRASH_SECONDS (the first `rm -rf` waits 30 s) is cut off
# after it, with NRV-W1205 and the tree still there, and the next call empties it: the call ends in
# a few seconds, not 30, and the trash lock is free afterwards.
trash_case bound
ci_as touch "$r/main/zig/f"
(. ci/cache.sh; CI_JOB_USER=$jobuser ci_trash_move "$r/main/zig") >/dev/null 2>&1
slow_reset
t0=$(now)
out=$( (. ci/cache.sh; PATH="$slow_rm_dir:$PATH" SLOW_RM=30 CI_TRASH_SECONDS=2 ci_trash_empty "$r/main") 2>&1)
t1=$(now)
is "a removal past CI_TRASH_SECONDS is cut off: bounded (under 10 s), W1205, the tree left, the trash lock free" "yes yes yes free" "$(awk -v a="$t0" -v b="$t1" 'BEGIN { print (b - a < 10) ? "yes" : "no" }') $(grep -q "NRV-W1205: .* was not emptied in 2 s" <<<"$out" && echo yes) $([ -n "$(ls -A "$r/main/.trash")" ] && echo yes) $(flock -x -n "$r/locks/main-trash.lock" true && echo free || echo held)"
out=$( (. ci/cache.sh; ci_trash_empty "$r/main") 2>&1)
is "and the next call empties it, silently" " " "$(ls -A "$r/main/.trash") $out"

# (k) With a mv that has no --no-copy (older coreutils), a tree on another file system is still
# not moved: the device test alone keeps mv from copying it. The stub hides the option from --help.
if [ "$(id -u)" = 0 ]; then
    mkdir -p "$tmp/stubs/oldmv"
    chmod 755 "$tmp/stubs/oldmv"
    printf '#!/bin/sh\nif [ "$1" = --help ]; then %s --help 2>&1 | grep -v -e --no-copy; exit 0; fi\nexec %s "$@"\n' "$(command -v mv)" "$(command -v mv)" >"$tmp/stubs/oldmv/mv"
    chmod 755 "$tmp/stubs/oldmv/mv"
    trash_case oldmv
    if mount -t tmpfs tmpfs "$r/main/zig" 2>/dev/null; then
        ro_mounts+=("$r/main/zig")
        : >"$r/main/zig/f"
        rc=0
        (. ci/cache.sh; PATH="$tmp/stubs/oldmv:$PATH" CI_JOB_USER=$jobuser ci_trash_move "$r/main/zig") >/dev/null 2>&1 || rc=$?
        is "no --no-copy in mv: a tree on another file system is still not moved or copied" "1 yes " "$rc $([ -e "$r/main/zig/f" ] && echo yes) $(ls -A "$r/main/.trash")"
        umount "$r/main/zig"
    else
        echo "note: no tmpfs mount here: the no --no-copy test was skipped" >&2
    fi
fi

# (l) A step that cannot take its own key lock at once (another step's prune or reset of that cache
# holds it) lets go of the branches' lock and main's before it waits: another branch is prepared and
# main's exclusive lock is free while it waits.
r=$(attack_tree ownlock)
: >"$r/locks/main.lock"
: >"$r/locks/$branch_key.lock"
chmod 600 "$r/locks/main.lock" "$r/locks/$branch_key.lock"
(
    exec 5>>"$r/locks/$branch_key.lock"
    flock -x 5
    sleep 4
) &
holder=$!
sleep 0.5
(
    exec 9<"$r/locks/main.lock"
    flock -s 9
    . ci/cache.sh
    CI_JOB_USER=$jobuser CI_LOCK_WAIT=10 ci_branch_prepare "$r" feature/atk >"$tmp/ownlock.out" 2>&1 && echo RC0 >>"$tmp/ownlock.out"
) &
waiter=$!
sleep 1.5
is "a step waiting for its own cache lock holds neither the branches' lock nor main's" "free free" "$(flock -x -n "$r/locks/branches.lock" true && echo -n free || echo -n held; echo -n ' '; flock -x -n "$r/locks/main.lock" true && echo free || echo held)"
wait "$holder" "$waiter" 2>/dev/null || true
is "and then it goes on (RC0, no warning)" yes "$(grep -q RC0 "$tmp/ownlock.out" && ! grep -q 'NRV-[EW]' "$tmp/ownlock.out" && echo yes)"

# --- Review 6003970990 (the twenty-second round): one removal of a mount's trash at a time, and no
# step waits for another's (locks/<mount>-trash.lock, flock -n); the size is measured after the job
# too; the record is written whole; the sweep keeps `tools`.
# A stub rm that waits on EVERY `rm -rf` (and counts the calls): a step that joined another's removal
# would wait too, and would add a call.
mkstub rmall "$real_rm" "case \"\$*\" in *-rf*) : >\"$mark/rm-started\"; echo x >>\"$mark/rm-calls\"; sleep \"\${SLOW_RM:-2}\" ;; esac"
mv "$tmp/stubs/rmall/rmall" "$tmp/stubs/rmall/rm"
slow_all_dir="$tmp/stubs/rmall"

# (m) Step A prunes an idle cache and removes it; step B, of another branch, starts while A's
# removal runs: it holds no lock A holds, finds the trash lock taken and skips the removal (no wait,
# no warning, no second `rm`). Mutants: a blocking flock, or no lock at all (a removal in every step).
r=$(attack_tree trashlock)
plant dir "$r/branches/b-old-00000002"
ci_as mkdir -p "$r/branches/b-old-00000002/zig/o"
ci_as touch "$r/branches/b-old-00000002/zig/o/f"
touch -d "20 days ago" "$r/branches/b-old-00000002"
: >"$r/locks/main.lock"
chmod 600 "$r/locks/main.lock"
slow_reset
(
    exec 9<"$r/locks/main.lock"
    flock -s 9
    . ci/cache.sh
    PATH="$slow_all_dir:$PATH" SLOW_RM=3 CI_JOB_USER=$jobuser CI_LOCK_WAIT=2 ci_branch_prepare "$r" feature/a >"$tmp/trashlock-a.out" 2>&1 && echo RC0 >>"$tmp/trashlock-a.out"
) &
trashlock_pid=$!
wait_for "$mark/rm-started" || { echo "FAIL the pruned tree was never removed (m)" >&2; fail=1; }
t0=$(now)
out=$( (. ci/cache.sh; PATH="$slow_all_dir:$PATH" SLOW_RM=3 CI_JOB_USER=$jobuser CI_LOCK_WAIT=2 ci_branch_prepare "$r" feature/b 2>&1 && echo RC0) || true)
t1=$(now)
is "(m) another branch's step while a removal runs (every rm waits 3 s): RC0, no warning" yes "$(grep -q RC0 <<<"$out" && ! grep -q "NRV-[EW]12" <<<"$out" && echo yes)"
is "(m) and it finished quickly (under 2 s), without a removal of its own" "yes 1" "$(awk -v a="$t0" -v b="$t1" 'BEGIN { print (b - a < 2) ? "yes" : "no" }') $(wc -l <"$mark/rm-calls" | tr -d ' ')"
is "(m) the trash is still being removed by A (not empty yet) while B is done" yes "$([ -n "$(ls -A "$r/branches/.trash")" ] && echo yes)"
wait "$trashlock_pid" 2>/dev/null || true
is "(m) A: RC0, no warning, the trash empty afterwards" yes "$(grep -q RC0 "$tmp/trashlock-a.out" && ! grep -q "NRV-[EW]12" "$tmp/trashlock-a.out" && [ -z "$(ls -A "$r/branches/.trash")" ] && echo yes)"
# The same for ci_trash_empty alone, and the lock is root's (a lock file in the lock directory, 0600).
trash_case lock2
ci_as touch "$r/main/zig/f"
(. ci/cache.sh; CI_JOB_USER=$jobuser ci_trash_move "$r/main/zig") >/dev/null 2>&1
slow_reset
(. ci/cache.sh; PATH="$slow_all_dir:$PATH" SLOW_RM=3 ci_trash_empty "$r/main") >/dev/null 2>&1 &
holder=$!
wait_for "$mark/rm-started" || { echo "FAIL the trash was never emptied (m2)" >&2; fail=1; }
is "(m) while one step removes, the trash lock is taken" held "$(flock -x -n "$r/locks/main-trash.lock" true && echo free || echo held)"
t0=$(now)
out=$( (. ci/cache.sh; PATH="$slow_all_dir:$PATH" SLOW_RM=3 ci_trash_empty "$r/main") 2>&1)
t1=$(now)
is "(m) a second call skips at once (under 1 s), silently, and runs no rm" "yes  1" "$(awk -v a="$t0" -v b="$t1" 'BEGIN { print (b - a < 1) ? "yes" : "no" }') $out $(wc -l <"$mark/rm-calls" | tr -d ' ')"
wait "$holder" 2>/dev/null || true
is "(m) the lock is free afterwards, the trash empty, the lock file 0600" "free  600" "$(flock -x -n "$r/locks/main-trash.lock" true && echo free || echo held) $(ls -A "$r/main/.trash") $(stat -c %a "$r/locks/main-trash.lock")"

# (n) The size is measured after the job too (ci_step_finish, in the step's tail): a job that grows
# the cache past CI_BRANCH_CACHE_MAX_GIB is seen by the next prune. The du stub says DU_GIB GiB.
printf '#!/bin/sh\nsleep "${DU_SLEEP:-0}"\nfor a; do :; done\nprintf "%%s\\t%%s\\n" "${DU_GIB:-1}" "$a"\n' >"$tmp/stubs/dufix.sh"
mkdir -p "$tmp/stubs/dufix"
chmod 755 "$tmp/stubs/dufix"
mv "$tmp/stubs/dufix.sh" "$tmp/stubs/dufix/du"
chmod 755 "$tmp/stubs/dufix/du"
r=$(attack_tree finish)
: >"$r/locks/main.lock"
chmod 600 "$r/locks/main.lock"
fin_dir="$r/branches/$branch_key"
(
    exec 9<"$r/locks/main.lock"
    flock -s 9
    . ci/cache.sh
    PATH="$tmp/stubs/dufix:$PATH" DU_GIB=1 CI_JOB_USER=$jobuser CI_LOCK_WAIT=2 ci_branch_prepare "$r" feature/atk >"$tmp/finish.out" 2>&1 || echo FAILED >>"$tmp/finish.out"
    ci_as touch "$fin_dir/zig/grown"
    # The job grew the tree (the stub's answer changes); a main step's tail leaves the record alone.
    PATH="$tmp/stubs/dufix:$PATH" DU_GIB=77 CI_JOB_USER=$jobuser ci_step_finish main "$r" "$fin_dir"
    echo "after a main tail: $(ci_branch_size "$r/locks" "$branch_key")" >>"$tmp/finish.out"
    PATH="$tmp/stubs/dufix:$PATH" DU_GIB=50 CI_JOB_USER=$jobuser ci_step_finish branch "$r" "$fin_dir"
    echo "after a branch tail: $(ci_branch_size "$r/locks" "$branch_key")" >>"$tmp/finish.out"
)
is "(n) before the job the record is 1 GiB; a main step's tail does not measure a branch" "after a main tail: 1" "$(grep 'after a main tail' "$tmp/finish.out")"
is "(n) a branch step's tail records what the job grew the cache to (50 GiB)" "after a branch tail: 50" "$(grep 'after a branch tail' "$tmp/finish.out")"
# The next step (another branch) prunes: the cache is over the bound (CI_BRANCH_CACHE_MAX_GIB=12), so it is dropped.
out=$( (. ci/cache.sh; PATH="$tmp/stubs/dufix:$PATH" DU_GIB=1 CI_BRANCH_CACHE_MAX_GIB=12 CI_JOB_USER=$jobuser CI_LOCK_WAIT=2 ci_branch_prepare "$r" feature/other 2>&1 && echo RC0) || true)
is "(n) the next prune drops the cache the job grew past the bound, its record and the trash too" "yes no no " "$(grep -q RC0 <<<"$out" && echo yes) $([ -e "$fin_dir" ] && echo yes || echo no) $([ -e "$r/locks/$branch_key.size" ] && echo yes || echo no) $(ls -A "$r/branches/.trash")"
# A tail also removes what the step's own prune left in the trash.
r=$(attack_tree finish2)
plant dir "$r/branches/b-old-00000002"
ci_as touch "$r/branches/b-old-00000002/f"
(. ci/cache.sh; CI_JOB_USER=$jobuser ci_trash_move "$r/branches/b-old-00000002") >/dev/null 2>&1
(. ci/cache.sh; ci_step_finish branch "$r" "")
is "(n) a branch step's tail empties the branches' trash (and tolerates no directory)" "" "$(ls -A "$r/branches/.trash")"

# (o) The record is written whole, whatever the other steps of the key write at the same moment: a
# slow writer of 1 and a fast one of 999999 (a timed-out walk): the file is one number or the
# other, never a mix ("1\n9999\n" reads as 0), and no temporary file is left. Mutants: a fixed
# `.new` name, or a write straight to the record.
r=$(attack_tree torn)
for round in 1 2 3; do
    (. ci/cache.sh; PATH="$tmp/stubs/dufix:$PATH" DU_GIB=1 DU_SLEEP=1 ci_branch_measure "$r/locks" bk "$r/branches") &
    slow_w=$!
    sleep 0.3
    (. ci/cache.sh; PATH="$tmp/stubs/dufix:$PATH" DU_GIB=999999 DU_SLEEP=0 ci_branch_measure "$r/locks" bk "$r/branches")
    wait "$slow_w" 2>/dev/null || true
    got=$(cat "$r/locks/bk.size")
    is "(o) two writers of one record (round $round): one whole number, none left over" "yes " "$([ "$got" = 1 ] || [ "$got" = 999999 ] && echo yes) $(find "$r/locks" -mindepth 1 ! -name bk.size -printf '%f\n')"
done

# (p) The sweep of old Jepsen run directories moves aside the runs only: `tools` (whose mtime is
# old) and a recent run stay.
r=$(attack_tree sweep)
mkdir -p "$r/jepsen/tools" "$r/jepsen/20200101T000000Z-3" "$r/jepsen/20260101T000000Z-4" "$r/jepsen/other"
mkdir -m 0700 "$r/jepsen/.trash"
touch -d "40 days ago" "$r/jepsen/tools" "$r/jepsen/20200101T000000Z-3" "$r/jepsen/other"
(. ci/cache.sh; ci_jepsen_sweep "$r/jepsen")
is "(p) an old run is moved aside; tools, a recent run and a name that is no run's stay" "no yes yes yes" "$([ -e "$r/jepsen/20200101T000000Z-3" ] && echo yes || echo no) $([ -d "$r/jepsen/tools" ] && echo yes) $([ -d "$r/jepsen/20260101T000000Z-4" ] && echo yes) $([ -d "$r/jepsen/other" ] && echo yes)"
is "(p) the old run is in the trash, for the step to remove after its lock" yes "$([ -n "$(ls -A "$r/jepsen/.trash")" ] && echo yes)"

# (q) The own-cache drop for size (the key's exclusive lock and the branches' lock held) renames and
# never removes: under the spy, no root `rm` runs while a lock is held exclusively or the branches' at
# all. Mutant: `rm -rf` of the directory there.
if [ "$(id -u)" = 0 ]; then
    r=$(attack_tree size3)
    mk_branch "$r/branches/$branch_key"
    ci_as touch "$r/branches/$branch_key/zig/marker"
    echo 999999 >"$r/locks/$branch_key.size"
    : >"$r/locks/main.lock"
    chmod 600 "$r/locks/main.lock"
    : >"$spy_log"
    out=$(
        exec 9<"$r/locks/main.lock"
        flock -s 9
        . ci/cache.sh
        PATH="$spy_path:$PATH" SPY_LOCKS="$r/locks" SPY_LOG="$spy_log" CI_JOB_USER=$jobuser CI_LOCK_WAIT=2 ci_branch_prepare "$r" feature/atk 2>&1 && echo RC0
    ) || true
    is "(q) an own cache over the bound: dropped (the marker is gone) and the step goes on" "yes no" "$(grep -q RC0 <<<"$out" && echo yes) $([ -e "$r/branches/$branch_key/zig/marker" ] && echo yes || echo no)"
    is "(q) root ran an rm, and none ran under an exclusive lock or the branches' lock" "yes 0" "$(grep -q '^rm' "$spy_log" && echo yes) $(grep -v '^rm .*:: -f ' "$spy_log" | grep -c -e excl: -e any: || true)"
else
    skip_note "the spy on the own-cache drop for size"
fi

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

# --- ci_step_run_with_tests (ci/lib.sh): the tail of a Woodpecker step (review 6001089776). Stub
# commands that log what they saw; the real step runs `bash ci/ci_test.sh` and `ci/job.sh` here.
st="$tmp/step"
mkdir -p "$st"
cat >"$st/tests.sh" <<'EOS'
#!/bin/bash
echo "tests fd9:$([ -e /proc/self/fd/9 ] && echo open || echo closed) fd10:$([ -e /proc/self/fd/10 ] && echo open || echo closed) fd11:$([ -e /proc/self/fd/11 ] && echo open || echo closed)" >>"$LOG"
[ -z "${T_SLEEP:-}" ] || sleep "$T_SLEEP"
exit "${T_RC:-0}"
EOS
cat >"$st/job.sh" <<'EOS'
#!/bin/bash
echo "job CI_SCRIPTS_TESTED=${CI_SCRIPTS_TESTED-unset} fd9:$([ -e /proc/self/fd/9 ] && echo open || echo closed) fd10:$([ -e /proc/self/fd/10 ] && echo open || echo closed) fd11:$([ -e /proc/self/fd/11 ] && echo open || echo closed)" >>"$LOG"
exit "${J_RC:-0}"
EOS
step_run() { # step_run JOB T_RC J_RC TEST_SECONDS [VAR=value...]: sets step_rc, step_log, step_err
    local job="$1" t_rc="$2" j_rc="$3" tsec="$4"
    shift 4
    rm -f "$st/log"
    step_rc=0
    (
        . ci/lib.sh
        export CI_KILL_AFTER=1
        for kv in "$@"; do export "${kv?}"; done
        exec 9<"$st/tests.sh" 10<"$st/tests.sh" 11<"$st/tests.sh" # open lock descriptors, as the step has
        # shellcheck disable=SC2034 # a nameref array, read by ci_step_run_with_tests
        tests_cmd=(env LOG="$st/log" T_RC="$t_rc" bash "$st/tests.sh")
        # shellcheck disable=SC2034 # a nameref array, read by ci_step_run_with_tests
        job_cmd=(env LOG="$st/log" J_RC="$j_rc" bash "$st/job.sh")
        ci_step_run_with_tests "$job" "$tsec" 60 tests_cmd job_cmd
    ) 2>"$st/err" || step_rc=$?
    step_log=$(tr '\n' '|' <"$st/log" 2>/dev/null || true)
    step_err=$(cat "$st/err")
    # The caller's arrays are named tests_cmd and job_cmd, as in woodpecker_step.sh: the function's own
    # namerefs must not take those names (review 6001444818: "circular name reference" on every step).
    ! grep -q "circular" <<<"$step_err" || { echo "FAIL ci_step_run_with_tests warns about its namerefs: $step_err" >&2; fail=1; }
}
step_run check-scripts 1 0 60 X=1
is "step tail: the tests fail, the job passes: the step fails" 1 "$step_rc"
is "step tail: check-scripts runs the tests first, then the job with CI_SCRIPTS_TESTED=1, both with fds 9, 10 and 11 closed" "tests fd9:closed fd10:closed fd11:closed|job CI_SCRIPTS_TESTED=1 fd9:closed fd10:closed fd11:closed|" "$step_log"
step_run check-scripts 0 3 60 X=1
is "step tail: the tests pass, the job fails: the job's status" 3 "$step_rc"
step_run check-scripts 0 0 60 X=1
is "step tail: both pass" 0 "$step_rc"
step_run check-scripts 1 3 60 X=1
is "step tail: both fail: the job's status" 3 "$step_rc"
step_run check 1 0 60 CI_SCRIPTS_TESTED=1
is "step tail: another job does not run the root tests (they would fail here), and passes alone" 0 "$step_rc"
is "step tail: another job runs alone, CI_SCRIPTS_TESTED unset (even if a pipeline variable set it), fds 9, 10 and 11 closed" "job CI_SCRIPTS_TESTED=unset fd9:closed fd10:closed fd11:closed|" "$step_log"
step_run check 0 3 60 X=1
is "step tail: another job's failure is the step's" 3 "$step_rc"
# The tests have a bound of their own, and the message names its knob; the job still runs after it.
step_run check-scripts 0 0 1 X=1 T_SLEEP=30
is "step tail: root tests past their bound fail the step" 124 "$step_rc"
grep -q "NRV-E1215: check-scripts's ci_test.sh, as root ran past its 1 seconds.*CI_SCRIPTS_TEST_MINUTES raises it" <<<"$step_err" || { echo "FAIL the tests' bound is not E1215 with its own knob: $step_err" >&2; fail=1; }
is "step tail: the job still ran after the tests timed out" "yes" "$(grep -q 'job CI_SCRIPTS_TESTED=1' <<<"$step_log" && echo yes)"
# The job's own timeout names CI_STEP_MINUTES.
out=$(. ci/lib.sh; CI_KILL_AFTER=1 ci_run_timed demo 1 sleep 30 2>&1 || true)
grep -q "NRV-E1215: demo ran past its 1 seconds.*CI_STEP_MINUTES raises it" <<<"$out" || { echo "FAIL the job's bound does not name CI_STEP_MINUTES: $out" >&2; fail=1; }
refuses NRV-E1208 "CI_SCRIPTS_TEST_MINUTES not a number" env CI_SCRIPTS_TEST_MINUTES=soon ci/woodpecker_step.sh check
refuses NRV-E1208 "CI_SCRIPTS_TEST_MINUTES zero" env CI_SCRIPTS_TEST_MINUTES=0 ci/woodpecker_step.sh check

# --- The box lock (decision O12, NRV-E1245): jobs hold locks/box.lock shared, integration exclusive,
# behind a turnstile. Real flock on files in a scratch lock directory.
bl="$tmp/boxlocks"
mkdir -m 700 "$bl"
box_hold() { # box_hold MODE MARKER SECONDS [WAIT]: a holder in the background; its pid (box_pid) is the sleep that holds the descriptors
    ( . ci/cache.sh; CI_BOX_WAIT="${4:-30}" ci_box_lock "$1" "$bl" && : >"$2" && exec sleep "$3" ) >/dev/null 2>&1 &
    box_pid=$!
}
box_try() { # box_try MODE WAIT: the output of one ci_box_lock; the last line is its status
    ( . ci/cache.sh; CI_BOX_WAIT="$2" ci_box_lock "$1" "$bl" && echo rc=0 || echo rc=1 ) 2>&1
}
box_rc() { tail -n 1 <<<"$1"; }
# Shared holders coexist, and the turnstile is let go after each.
box_hold shared "$tmp/s1" 4
wait_for "$tmp/s1" || { echo "FAIL the first shared holder never held the box lock" >&2; fail=1; }
out=$(box_try shared 2)
is "box lock: a second shared holder gets it beside the first" "rc=0" "$(box_rc "$out")"
is "box lock: a shared holder does not keep the turnstile" free "$(flock -x -n "$bl/turnstile.lock" true && echo free || echo held)"
out=$(box_try exclusive 1)
is "box lock: an exclusive holder cannot get it beside a shared one" "rc=1" "$(box_rc "$out")"
grep -q "NRV-E1245: the box lock .*box.lock was not free for the exclusive holder within 1 s: short jobs hold it shared" <<<"$out" || { echo "FAIL box lock: exclusive beside shared: no NRV-E1245: $out" >&2; fail=1; }
wait "$box_pid" || true
# The exclusive holder excludes shared and exclusive ones, with its code, and is not run unlocked.
rm -f "$tmp/x1"
box_hold exclusive "$tmp/x1" 4
wait_for "$tmp/x1" || { echo "FAIL the exclusive holder never held the box lock" >&2; fail=1; }
out=$(box_try shared 1)
is "box lock: a shared holder cannot get it beside the exclusive one" "rc=1" "$(box_rc "$out")"
grep -q "NRV-E1245: .*turnstile.lock was not free for the shared holder within 1 s: an integration step holds the turnstile" <<<"$out" || { echo "FAIL box lock: shared beside exclusive: no NRV-E1245: $out" >&2; fail=1; }
out=$(box_try exclusive 1)
is "box lock: a second exclusive holder cannot get it" "rc=1" "$(box_rc "$out")"
wait "$box_pid" || true
out=$(box_try shared 2)
is "box lock: free again when the exclusive holder ends" "rc=0" "$(box_rc "$out")"
# The turnstile: an exclusive step waiting for a shared holder keeps new shared steps out (control:
# without a waiter a new shared step gets in beside the holder).
rm -f "$tmp/s1" "$tmp/x1"
box_hold shared "$tmp/s1" 7
s1_pid=$box_pid
wait_for "$tmp/s1" || { echo "FAIL the shared holder never held the box lock" >&2; fail=1; }
out=$(box_try shared 2)
is "box lock: control: a new shared step gets in beside a shared holder" "rc=0" "$(box_rc "$out")"
box_hold exclusive "$tmp/x1" 4
x_pid=$box_pid
for _ in $(seq 50); do flock -x -n "$bl/turnstile.lock" true || break; sleep 0.1; done
is "box lock: the waiting exclusive step holds the turnstile" held "$(flock -x -n "$bl/turnstile.lock" true && echo free || echo held)"
out=$(box_try shared 1)
is "box lock: a waiting exclusive step keeps a new shared step out" "rc=1" "$(box_rc "$out")"
grep -q "NRV-E1245: .*turnstile.lock was not free for the shared holder within 1 s: an integration step holds the turnstile" <<<"$out" || { echo "FAIL box lock: turnstile: no NRV-E1245 naming the integration step: $out" >&2; fail=1; }
wait "$s1_pid" || true
wait_for "$tmp/x1" || { echo "FAIL box lock: the exclusive step never got the lock after the shared holder ended" >&2; fail=1; }
out=$(box_try shared 1)
is "box lock: the exclusive step keeps new shared steps out while it runs" "rc=1" "$(box_rc "$out")"
wait "$x_pid" || true
out=$(box_try shared 2)
is "box lock: shared steps run again after the exclusive one" "rc=0" "$(box_rc "$out")"
# Knobs and misuse.
out=$( ( . ci/cache.sh; CI_BOX_WAIT=soon ci_box_lock shared "$bl" && echo rc=0 || echo rc=1 ) 2>&1)
grep -q "NRV-E1208: CI_BOX_WAIT='soon'" <<<"$out" || { echo "FAIL box lock: CI_BOX_WAIT not a number: $out" >&2; fail=1; }
out=$( ( . ci/cache.sh; CI_INTEGRATION_RUN_MINUTES=0 ci_box_lock shared "$bl" && echo rc=0 || echo rc=1 ) 2>&1)
grep -q "NRV-E1208: CI_INTEGRATION_RUN_MINUTES='0'" <<<"$out" || { echo "FAIL box lock: CI_INTEGRATION_RUN_MINUTES zero: $out" >&2; fail=1; }
out=$( ( . ci/cache.sh; ci_box_lock sideways "$bl" && echo rc=0 || echo rc=1 ) 2>&1)
grep -q "NRV-B1203" <<<"$out" || { echo "FAIL box lock: a bad mode: $out" >&2; fail=1; }
# A holder that is killed (a cancelled step: SIGKILL of the container's processes) frees the lock.
rm -f "$tmp/x1"
box_hold exclusive "$tmp/x1" 60
wait_for "$tmp/x1" || { echo "FAIL the exclusive holder never held the box lock" >&2; fail=1; }
out=$(box_try shared 1)
is "box lock: control: a live exclusive holder keeps shared ones out" "rc=1" "$(box_rc "$out")"
kill -9 "$box_pid"
wait "$box_pid" 2>/dev/null || true
out=$(box_try exclusive 2)
is "box lock: a killed exclusive holder frees the lock (and the turnstile)" "rc=0" "$(box_rc "$out")"
rm -f "$tmp/s1"
box_hold shared "$tmp/s1" 60
wait_for "$tmp/s1" || { echo "FAIL the shared holder never held the box lock" >&2; fail=1; }
kill -9 "$box_pid"
wait "$box_pid" 2>/dev/null || true
out=$(box_try exclusive 2)
is "box lock: a killed shared holder frees the lock" "rc=0" "$(box_rc "$out")"
# ci_box_unlock lets go of both; a failed wait leaves nothing held; the upgrade of a step that holds
# the lock shared is refused (it would deadlock two integration steps): release first, then ask.
out=$( ( . ci/cache.sh; ci_box_lock shared "$bl" && ci_box_unlock && flock -x -n "$bl/box.lock" true && flock -x -n "$bl/turnstile.lock" true && echo rc=0 || echo rc=1 ) 2>&1)
is "box lock: ci_box_unlock lets go of the box lock" "rc=0" "$(box_rc "$out")"
out=$( ( . ci/cache.sh; ci_box_lock shared "$bl" && ci_box_lock exclusive "$bl" && echo rc=0 || echo rc=1 ) 2>&1)
is "box lock: waiting for exclusive while holding shared is refused" "rc=1" "$(box_rc "$out")"
grep -q "NRV-B1203: ci_box_lock exclusive: called while holding the box lock (shared)" <<<"$out" || { echo "FAIL box lock: a held lock is not refused with NRV-B1203: $out" >&2; fail=1; }
out=$( ( . ci/cache.sh; ci_box_lock shared "$bl" && ci_box_unlock && ci_box_lock exclusive "$bl" && echo rc=0 || echo rc=1 ) 2>&1)
is "box lock: shared, released, then exclusive (the step's order) works" "rc=0" "$(box_rc "$out")"
rm -f "$tmp/s1"
box_hold shared "$tmp/s1" 4
wait_for "$tmp/s1" || { echo "FAIL the shared holder never held the box lock" >&2; fail=1; }
out=$( ( . ci/cache.sh; CI_BOX_WAIT=1 ci_box_lock exclusive "$bl" || { flock -x -n "$bl/turnstile.lock" true && echo free; } ) 2>&1)
is "box lock: a failed exclusive wait leaves the turnstile free" free "$(tail -n 1 <<<"$out")"
wait "$box_pid" || true
# The step: the long jobs take no lock, the short ones shared, integration builds shared then runs
# exclusive, each around the run alone (static); the descriptors are closed for children (static).
is "the long jobs take no box lock; integration builds then runs exclusive; the rest shared (static)" "1 1 1 1 1 1" "$(grep -c '^    fuzz-long | vopr-long | jepsen) box=none ;;$' ci/woodpecker_step.sh || true) $(grep -c '^    integration) box=integration ;;$' ci/woodpecker_step.sh || true) $(grep -c '^    \*) box=shared ;;$' ci/woodpecker_step.sh || true) $(grep -c '^    run_in_box shared "integration.s build" "\$minutes" build_cmd || status=\$?$' ci/woodpecker_step.sh || true) $(grep -c '^        run_in_box exclusive integration "\$run_minutes" job_cmd || status=\$?$' ci/woodpecker_step.sh || true) $(grep -c '^    run_in_box "\$box" "\$job" "\$minutes" job_cmd || status=\$?$' ci/woodpecker_step.sh || true)"
is "the lock is let go right after the run, before the tail (static)" yes "$(r=$(grep -n '^    ci_box_unlock$' ci/woodpecker_step.sh | cut -d: -f1); f=$(grep -n '^ci_step_finish ' ci/woodpecker_step.sh | cut -d: -f1); [ -n "$r" ] && [ -n "$f" ] && [ "$r" -lt "$f" ] && echo yes)"
is "the step closes the box lock's fds 10 and 11 for install_zig, the job and the root tests (static)" "1 2" "$(grep -c 'ci/install_zig.sh .* 10<&- 11<&-' ci/woodpecker_step.sh || true) $(grep -c '9<&- 10<&- 11<&-' ci/lib.sh || true)"
is "no box lock is taken before the first apt-get, nor by the top of the step (static)" 0 "$(grep -c '^ci_box_lock ' ci/woodpecker_step.sh || true)"

# --- The suite is hermetic (review 6001089776): the root run in a Woodpecker step has the step's
# environment, and a step exports CI_BRANCH_PRUNE_ALL=1 when the box is low on disk. Run the whole
# suite with every knob it exercises set to something hostile; it must still be ok. CI_TEST_NESTED
# stops it from running itself again.
if [ -z "${CI_TEST_NESTED:-}" ]; then
    nested=$(env CI_TEST_TMP="$tmp" CI_TEST_NESTED=1 CI_BRANCH_PRUNE_ALL=1 CI_DOCKER_MAX_BYTES=10 CI_LOCK_WAIT=0 CI_MAIN_LOCK_WAIT=0 \
        CI_BRANCH_CACHES=0 CI_BRANCH_CACHE_DAYS=0 CI_BRANCH_CACHE_MAX_GIB=0 CI_BRANCH_SEED_MAX_GIB=0 CI_PRUNE_WAIT=0 \
        CI_FREE_MIN_GIB=99999 CI_JEPSEN_WAIT=0 CI_STEP_MINUTES=x CI_SCRIPTS_TEST_MINUTES=x CI_TRASH_SECONDS=x CI_KILL_AFTER=0 CI_ARCH=aarch64 \
        CI_DOCKER_BIN_DIR=/nonexistent CI_DOCKER_CLIENT_URL=file:///nonexistent CI_JOB_USER=nobody CI_CACHE_SHARED=0 \
        CI_TOOLCHAIN_DIR=/nonexistent CI_TOOLCHAIN_WRITE=0 CI_COMMIT_BRANCH=main CI_PIPELINE_EVENT=push CI_SECCOMP=no \
        bash "$root/ci/ci_test.sh" 2>&1) || true
    grep -q '^ci_test: ok$' <<<"$nested" || { echo "FAIL the suite with every CI_* knob set (as a step or a pipeline variable can): $(grep -v '^note' <<<"$nested" | head -20)" >&2; fail=1; }
fi

if [ "$fail" = 0 ]; then echo "ci_test: ok"; fi
exit "$fail"
