#!/usr/bin/env bash
# Installs Docker's static client, pinned, for the Jepsen step (which drives the host's Docker
# through its socket): ci/docker_client.sh VERSION SHA256 CACHE_DIR
#
# The release archive (82 MB) is kept in CACHE_DIR, checked against SHA256 on every use and
# fetched again if it differs, and only the `docker` binary is unpacked, into $CI_DOCKER_BIN_DIR
# (default /usr/local/bin). NRV-E1204 if this is not x86_64 (the pin is), NRV-E1205 if the
# download does not match its pin, NRV-E1230 if the archive's path holds something that is not a
# regular file (a link, a directory) or one over CI_DOCKER_MAX_BYTES, or cannot be read.
# CI_DOCKER_CLIENT_URL replaces the download URL (for the table test); CI_ARCH replaces `uname -m`.
#
# An optional fourth word splits the work for a step that runs as root over a cache a job writes:
# `fetch` only downloads and verifies the archive (run it as the job's user), `install` only copies the
# archive privately, checks the copy and unpacks it (root). Without it, both.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

version="${1:?usage: ci/docker_client.sh VERSION SHA256 CACHE_DIR}"
sha="${2:?usage: ci/docker_client.sh VERSION SHA256 CACHE_DIR}"
dir="${3:?usage: ci/docker_client.sh VERSION SHA256 CACHE_DIR}"
phase="${4:-all}"
case "$phase" in all | fetch | install) ;; *) echo "usage: ci/docker_client.sh VERSION SHA256 CACHE_DIR [fetch|install]" >&2; exit 2 ;; esac
bin="${CI_DOCKER_BIN_DIR:-/usr/local/bin}"
archive="$dir/docker-$version.tgz"
# The release archive is 82 MB (29.9.3). The root copy in `install` reads at most one byte more than
# this, so a file that is endless (or just large) cannot fill the container's layer; it is far under
# any disk and leaves room for a larger release.
max_bytes="${CI_DOCKER_MAX_BYTES:-$((100 * 1024 * 1024))}"

# not_regular: NRV-E1230 if the archive's path is a link or anything but a regular file (a missing
# one is not: fetch makes it). A directory there would take the download into itself (mv) and fail
# every later run, so both phases look first.
not_regular() {
    if [ -L "$archive" ] || { [ -e "$archive" ] && [ ! -f "$archive" ]; }; then
        ci_error "NRV-E1230: $archive is a link or not a regular file: on the host, rm -rf it (it is only a cache) and start the pipeline again"
        return 0
    fi
    return 1
}

if [ "${CI_ARCH:-$(uname -m)}" != x86_64 ]; then
    ci_error "NRV-E1204: the pinned Docker client is x86_64; this machine is ${CI_ARCH:-$(uname -m)}"
    exit 1
fi
if [ "$phase" != install ] && not_regular; then exit 1; fi
if [ "$phase" != install ] && { [ ! -f "$archive" ] || ! echo "$sha  $archive" | sha256sum -c - >/dev/null 2>&1; }; then
    mkdir -p "$dir"
    partial="$archive.partial.$$"
    curl -fsSL --retry 3 -o "$partial" \
        "${CI_DOCKER_CLIENT_URL:-https://download.docker.com/linux/static/stable/x86_64/docker-$version.tgz}"
    if ! echo "$sha  $partial" | sha256sum -c - >/dev/null 2>&1; then
        rm -f "$partial"
        ci_error "NRV-E1205: docker-$version.tgz does not match its pinned sha256 $sha"
        exit 1
    fi
    mv "$partial" "$archive"
fi
[ "$phase" != fetch ] || exit 0
# What is unpacked is what was checked: the archive sits where a job can write, so a check by path
# and an unpack by path could see two files. One copy, in a directory only this user can use, is
# checked and unpacked.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
if not_regular; then exit 1; fi
# head, not cat: bounded. Its stderr is kept in memory (a full disk could not hold a file for it).
if ! why=$(head -c "$((max_bytes + 1))" -- "$archive" 2>&1 >"$work/docker.tgz"); then
    ci_error "NRV-E1230: could not read $archive (${why##*: }): on the host, rm -rf it and start the pipeline again"
    exit 1
fi
if [ "$(stat -c %s "$work/docker.tgz")" -gt "$max_bytes" ]; then
    ci_error "NRV-E1230: $archive is over $max_bytes bytes (the release is 82 MB): on the host, rm -rf it and start the pipeline again"
    exit 1
fi
if ! echo "$sha  $work/docker.tgz" | sha256sum -c - >/dev/null 2>&1; then
    ci_error "NRV-E1205: docker-$version.tgz does not match its pinned sha256 $sha"
    exit 1
fi
mkdir -p "$bin"
tar --no-same-owner -xzf "$work/docker.tgz" -C "$bin" --strip-components=1 docker/docker
