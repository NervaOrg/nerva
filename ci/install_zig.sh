#!/usr/bin/env bash
# Installs the Zig pinned by zig/download.sh, from a toolchain kept under the cache directory
# ($XDG_CACHE_HOME, else ~/.cache) when one is there. Run from the repository root.
#
# The toolchain is kept in nerva-toolchain/zig-<hash of download.sh> and linked into ./zig; Zig
# finds its lib next to the real binary. A copy is used only if complete and it runs; otherwise it
# is replaced by a fresh download, written aside under a name of this process's own and renamed,
# so two jobs sharing the cache (Woodpecker on one host) never see half a toolchain. download.sh
# then checks the version, as before.
#
# First, unless the cache is shared with jobs running at the same time (CI_CACHE_SHARED=1, where
# ci/woodpecker_step.sh prunes under a lock instead), a disk left too full by earlier jobs is
# freed (.github/scripts/free_disk.sh, N65).
set -euo pipefail

[ "${CI_CACHE_SHARED:-}" = 1 ] || .github/scripts/free_disk.sh
cache="${XDG_CACHE_HOME:-$HOME/.cache}/nerva-toolchain"
toolchain="$cache/zig-$(sha256sum zig/download.sh | cut -c1-16)"
if [ -x "$toolchain/zig" ] && [ -f "$toolchain/lib/std/std.zig" ]; then
    rm -rf zig/zig zig/lib
    ln -s "$toolchain/zig" zig/zig
    ln -s "$toolchain/lib" zig/lib
fi
if ! ./zig/zig env > /dev/null 2>&1 || [ ! -f zig/lib/std/std.zig ]; then
    rm -rf zig/zig zig/lib
    ./zig/download.sh
    mkdir -p "$cache"
    partial="$toolchain.partial.$$"
    rm -rf "$partial"
    mkdir "$partial"
    cp -a zig/zig zig/lib "$partial/"
    # Another job may have finished the same toolchain first; then ours is not needed.
    if [ -x "$toolchain/zig" ] && [ -f "$toolchain/lib/std/std.zig" ]; then
        rm -rf "$partial"
    else
        rm -rf "$toolchain"
        mv "$partial" "$toolchain" # macOS's mv has no -T; the rename is atomic all the same
        rm -rf "$partial"
    fi
fi
echo "Zig $(./zig/zig version) from $(readlink -f zig/zig)"
./zig/download.sh
