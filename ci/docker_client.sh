#!/usr/bin/env bash
# Installs Docker's static client, pinned, for the Jepsen step (which drives the host's Docker
# through its socket): ci/docker_client.sh VERSION SHA256 CACHE_DIR
#
# The release archive (82 MB) is kept in CACHE_DIR, checked against SHA256 on every use and
# fetched again if it differs, and only the `docker` binary is unpacked, into $CI_DOCKER_BIN_DIR
# (default /usr/local/bin). NRV-E1204 if this is not x86_64 (the pin is), NRV-E1205 if the
# download does not match its pin. CI_DOCKER_CLIENT_URL replaces the download URL (for the table
# test); CI_ARCH replaces `uname -m`.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

version="${1:?usage: ci/docker_client.sh VERSION SHA256 CACHE_DIR}"
sha="${2:?usage: ci/docker_client.sh VERSION SHA256 CACHE_DIR}"
dir="${3:?usage: ci/docker_client.sh VERSION SHA256 CACHE_DIR}"
bin="${CI_DOCKER_BIN_DIR:-/usr/local/bin}"
archive="$dir/docker-$version.tgz"

if [ "${CI_ARCH:-$(uname -m)}" != x86_64 ]; then
    ci_error "NRV-E1204: the pinned Docker client is x86_64; this machine is ${CI_ARCH:-$(uname -m)}"
    exit 1
fi
if [ ! -f "$archive" ] || ! echo "$sha  $archive" | sha256sum -c - >/dev/null 2>&1; then
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
mkdir -p "$bin"
tar --no-same-owner -xzf "$archive" -C "$bin" --strip-components=1 docker/docker
