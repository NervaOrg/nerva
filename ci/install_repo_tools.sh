#!/usr/bin/env bash
# The package repositories' tools, pinned to what Ubuntu 24.04 offers and asserted, so an image
# change fails here (NRV-E1139) and does not silently change the bytes (docs/releases/packages.md,
# "Tools on the runner, pinned"). gpg is the image's 2.4. Runs as root, or through sudo.
set -euo pipefail

sudo=""
[ "$(id -u)" = 0 ] || sudo=sudo
export DEBIAN_FRONTEND=noninteractive
$sudo apt-get -o Acquire::Retries=5 update -qq
$sudo apt-get -o Acquire::Retries=5 install -y -qq apt-utils=2.8.4ubuntu0.1 \
    createrepo-c=0.17.3-2ubuntu3 rpm=4.18.2+dfsg-2.1build2 sqv=1.1.0-1build2 gnupg jq
tool_is() { # <tool> <expected first line>
    got=$("$1" --version 2>&1 | head -n1)
    case $got in
        "$2" | "$2"[!0-9.]*) ;;
        *) echo "error[NRV-E1139]: ci/install_repo_tools.sh: $1 reads '$got', not '$2'" >&2; exit 1 ;;
    esac
}
tool_is apt-ftparchive "apt 2.8.4"
tool_is createrepo_c "Version: 0.17.3"
tool_is rpmsign "RPM version 4.18.2"
gpg --version | head -n1 | grep -q 'gpg (GnuPG) 2\.4\.' ||
    { echo "error[NRV-E1139]: ci/install_repo_tools.sh: gpg is not 2.4" >&2; exit 1; }
