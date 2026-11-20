#!/usr/bin/env bash
# Installs the Zig pinned by zig/download.sh. Run from the repository root.
#
# The pinned archive (zig-<arch>-<os>-<version>.tar.xz) is kept as <sha256>.tar.xz in a directory
# of toolchains, $CI_TOOLCHAIN_DIR (else $XDG_CACHE_HOME/nerva-toolchain, else
# ~/.cache/nerva-toolchain). Every use copies it into zig/cache and runs zig/download.sh, which
# checks the archive against the sha256 it pins, downloads again on a mismatch and unpacks into
# the job's own zig/: so a cached toolchain is verified every time, never trusted by its name or
# by what it prints, and two jobs never share an unpacked toolchain (nothing to race on).
#
# The directory is written only when CI_TOOLCHAIN_WRITE is not 0 (ci/woodpecker_step.sh sets 0
# outside main, decision O4), and by an atomic rename of a copy of a verified archive.
#
# First, unless the cache is shared with jobs running at the same time (CI_CACHE_SHARED=1, where
# ci/woodpecker_step.sh prunes under a lock instead), a disk left too full by earlier jobs is
# freed (.github/scripts/free_disk.sh, N65).
set -euo pipefail
. "$(dirname "$0")/lib.sh"

[ "${CI_CACHE_SHARED:-}" = 1 ] || .github/scripts/free_disk.sh
dir="${CI_TOOLCHAIN_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/nerva-toolchain}"

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d ' ' -f 1; else shasum -a 256 "$1" | cut -d ' ' -f 1; fi; }

case "$(uname -m)" in arm64 | aarch64) arch=aarch64 ;; *) arch=x86_64 ;; esac
case "$(uname)" in Darwin) os=macos ;; *) os=linux ;; esac
# The pin: the line of ZIG_CHECKSUMS for this machine, "<url> <sha256>".
pin=$(grep -E "/zig-$arch-$os-[0-9.]+\.tar\.xz [0-9a-f]{64}\$" zig/download.sh | head -1 || true)
archive=$(basename "${pin%% *}")
sha=${pin##* }

rm -rf zig/zig zig/lib zig/doc
mkdir -p zig/cache
cached="$dir/$sha.tar.xz"
if [ -n "$pin" ] && [ -f "$cached" ]; then
    if [ "$(sha256 "$cached")" = "$sha" ]; then
        cp "$cached" "zig/cache/$archive"
    else
        ci_warning "NRV-W1201: $cached does not match its sha256: downloading the toolchain again"
    fi
fi
./zig/download.sh
if [ -n "$pin" ] && [ "${CI_TOOLCHAIN_WRITE:-1}" != 0 ] && [ -f "zig/cache/$archive" ] &&
    { [ ! -f "$cached" ] || [ "$(sha256 "$cached")" != "$sha" ]; } &&
    [ "$(sha256 "zig/cache/$archive")" = "$sha" ]; then
    mkdir -p "$dir"
    partial="$dir/.$sha.$$.partial"
    cp "zig/cache/$archive" "$partial"
    mv "$partial" "$cached" # the rename is atomic, on macOS as well
fi
echo "Zig $(./zig/zig version) from $(readlink -f zig/zig)"
