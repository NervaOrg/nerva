#!/usr/bin/env bash
# Table test for the CI scripts' own refusals and cache rules (NRV-E1201 to E1210, NRV-W1201 and
# W1202, docs/ERRORS.md; decision O4). Needs flock. Takes a few seconds; touches only a scratch
# directory. Not covered, as they need a Woodpecker step or a daemon: NRV-E1203 (the Docker socket
# is not mounted), the io_uring check on a real refusing daemon, and "main's cache is not writable
# in a pipeline for main" when this runs as root (root writes through a read-only mode).
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
out=$(bash -c ". ci/lib.sh; ci_mask $key; echo \"key $key and ${key:0:16}x\" | ci_redact")
is "ci_redact" "key *** and ***x" "$out"
is "ci_redact without a mask" "plain" "$(bash -c '. ci/lib.sh; echo plain | ci_redact')"

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

# A branch's cache is a plain copy of main's: not a link, and writing it leaves main's alone.
echo seed >"$c/main/zig-local/entry"
(
    . ci/cache.sh
    ci_branch_prepare "$c" feature/one
    echo "$CI_BRANCH_DIR" >"$tmp/dir1"
)
d1=$(cat "$tmp/dir1")
is "branch cache seeded" seed "$(cat "$d1/zig-local/entry")"
is "branch cache is a copy, not a link" 1 "$(stat -c %h "$d1/zig-local/entry")"
echo changed >>"$d1/zig-local/entry"
is "main untouched by a branch" seed "$(cat "$c/main/zig-local/entry")"
# Main's cache over the seed limit: the branch starts empty (du rounds up to a whole GiB).
(
    . ci/cache.sh
    CI_BRANCH_SEED_MAX_GIB=0 ci_branch_prepare "$c" feature/two 2>/dev/null
    echo "$CI_BRANCH_DIR" >"$tmp/dir2"
)
is "oversize main is not copied" "" "$(ls -A "$(cat "$tmp/dir2")/zig-local")"
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
# The caches of feature/one and /two are newer, so they take the two places; old6 is the oldest but
# a job holds it.
is "old branch caches pruned, the one in use kept" "yes" "$([ -d "$c/branches/b-old6-00000006" ] && [ ! -d "$c/branches/b-old5-00000005" ] && [ ! -d "$c/branches/b-old1-00000001" ] && echo yes)"
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true

# ci_main_prune: empties main's Zig caches when nobody holds them; NRV-W1202 when others do.
echo x >"$c/main/zig-local/entry"
touch "$c/main/.lock"
(
    . ci/cache.sh
    exec 9<"$c/main/.lock"
    CI_PRUNE_WAIT=1 ci_main_prune "$c"
)
is "main pruned when idle" "" "$(ls -A "$c/main/zig-local")"
echo x >"$c/main/zig-local/entry"
flock -s "$c/main/.lock" sleep 20 &
holder=$!
sleep 0.3
out=$(
    . ci/cache.sh
    exec 9<"$c/main/.lock"
    CI_PRUNE_WAIT=1 ci_main_prune "$c" 2>&1
)
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
grep -q NRV-W1202 <<<"$out" || { echo "FAIL prune busy: no NRV-W1202 in: $out" >&2; fail=1; }
is "main kept when busy" entry "$(ls "$c/main/zig-local")"

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
