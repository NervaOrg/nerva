#!/usr/bin/env bash
# Nerva's part of the Woodpecker setup, after woodpecker-bootstrap.sh (README.md, "Nerva on
# Woodpecker"). Two modes:
#
#   On every agent box, as root:
#     bash nerva-woodpecker.sh host
#   Checks Docker (and that its daemon carries the io_uring seccomp profile, which
#   woodpecker-bootstrap.sh installs), /dev/fuse and /dev/kvm, and creates the cache directories
#   under /var/cache/nerva-ci (main, branches and jepsen: decision O4).
#
#   On your laptop (needs curl and jq), with a personal token from Woodpecker (your avatar, then
#   Personal access token):
#     WOODPECKER_SERVER=https://ci.example.org WOODPECKER_TOKEN=... bash nerva-woodpecker.sh repo OWNER/NAME
#   Enables the repository if it is not yet, then sets: pull requests off, approval for forks,
#   a 360-minute timeout, and Trusted for volumes and network (not security: no step is
#   privileged, decision O4). It reads the settings back and fails if any did not take.
#
# Both modes can run again: each only changes what is not yet as it should be. The last line is
# `nerva-woodpecker: OK ...` or `nerva-woodpecker: FAIL ...`.
set -euo pipefail

fail() { echo "nerva-woodpecker: FAIL $*" >&2; exit 1; }
say() { echo "nerva-woodpecker: $*"; }
io_uring_probe() { # a throwaway container on the pinned image: io_uring_setup (425) under the daemon's own profile
    docker run --rm docker.io/library/ubuntu:24.04@sha256:73b999393d07f2bf65a40373778a44dc9a6d54ad7718d29247d8ff9413c4d6a8 \
        perl -e 'exit(syscall(425, 1, "\0" x 120) < 0 ? 1 : 0)' >/dev/null 2>&1
}

host() {
    [ "$(id -u)" = 0 ] || fail "run as root: ssh -t root@BOX bash nerva-woodpecker.sh host"
    command -v docker >/dev/null || fail "no docker: run woodpecker-bootstrap.sh on this box first"
    docker info >/dev/null 2>&1 || fail "docker is installed but not running: systemctl status docker"
    docker ps --format '{{.Names}}' | grep -q woodpecker-agent ||
        fail "no woodpecker-agent container: run woodpecker-bootstrap.sh (or its agent mode) first"

    # Jepsen's LazyFS mounts FUSE inside the node containers.
    [ -e /dev/fuse ] || modprobe fuse 2>/dev/null || true
    [ -e /dev/fuse ] || fail "/dev/fuse is missing and \`modprobe fuse\` did not add it"
    echo fuse > /etc/modules-load.d/nerva-ci.conf

    if [ -e /dev/kvm ]; then
        say "/dev/kvm present"
    else
        say "warning: no /dev/kvm (enable virtualisation in the BIOS); Nerva's workflows do not need it yet"
    fi

    # No step is privileged, so io_uring needs the daemon's own profile (ops/ci/docker/README.md).
    io_uring_probe ||
        fail "NRV-E1201: a throwaway container cannot create an io_uring: the daemon does not run the profile ops/ci/docker/seccomp-io_uring.json; run woodpecker-bootstrap.sh again, from the directory that holds docker/seccomp-io_uring.json"

    # The caches the workflows mount (.woodpecker/*.yaml); uid 1001 is the `ci` user the jobs run
    # as. main/ is written only by pipelines for a push to main, which mount it writable; the others
    # mount it read-only and write branches/. jepsen/ keeps each Jepsen run's store.
    install -d -m 0755 -o 1001 -g 1001 /var/cache/nerva-ci /var/cache/nerva-ci/main \
        /var/cache/nerva-ci/branches /var/cache/nerva-ci/jepsen
    # What the first layout left (one shared cache for every branch) is no longer read.
    local old
    old=$(cd /var/cache/nerva-ci && ls -d nerva-toolchain zig zig-local zig-cache 2>/dev/null | tr '\n' ' ')
    [ -z "$old" ] || say "note: /var/cache/nerva-ci holds the old layout ($old); nothing reads it now, delete it when you like"
    local avail
    avail=$(df --output=avail -B1G /var/cache/nerva-ci | tail -1 | tr -d ' ')
    [ "$avail" -ge 100 ] ||
        say "warning: only $avail GiB free under /var/cache/nerva-ci; a push runs 15 workflows, the integration one alone takes 3.5 GiB"

    local cpus mem
    cpus=$(nproc)
    mem=$(awk '/^MemTotal:/ {print int($2 / 1048576)}' /proc/meminfo)
    say "OK host $(hostname): $cpus CPUs, $mem GiB, $avail GiB free for /var/cache/nerva-ci"
}

# The token goes to curl in a header file (-H @file), not on its command line, where `ps` would
# show it to every user of the machine.
api_header=
api() { # api METHOD PATH [JSON]
    if [ -z "$api_header" ]; then
        api_header=$(mktemp)
        trap 'rm -f "$api_header"' EXIT
        chmod 600 "$api_header"
        printf 'Authorization: Bearer %s\n' "$WOODPECKER_TOKEN" > "$api_header"
    fi
    local args=(-fsS -X "$1" -H "@$api_header" -H 'Content-Type: application/json')
    [ $# -lt 3 ] || args+=(--data "$3")
    curl "${args[@]}" "${WOODPECKER_SERVER%/}/api$2"
}

repo() {
    local name="${1:-}"
    [[ "$name" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || fail "usage: nerva-woodpecker.sh repo OWNER/NAME"
    : "${WOODPECKER_SERVER:?set WOODPECKER_SERVER, e.g. https://ci.example.org}"
    : "${WOODPECKER_TOKEN:?set WOODPECKER_TOKEN (Woodpecker: your avatar, then Personal access token)}"
    command -v jq >/dev/null || fail "needs jq"
    api GET /user >/dev/null || fail "the server or the token was refused: check WOODPECKER_SERVER and WOODPECKER_TOKEN"

    local id
    if ! id=$(api GET "/repos/lookup/$name" 2>/dev/null | jq -er .id); then
        # Not enabled yet: find it among the forge's repositories this user can see.
        local remote
        remote=$(api GET '/user/repos?all=true' |
            jq -er --arg n "$name" '.[] | select(.full_name == $n) | .forge_remote_id') ||
            fail "$name is not among your forge's repositories as Woodpecker sees them (are you an admin of it?)"
        id=$(api POST "/repos?forge_remote_id=$remote" | jq -er .id) || fail "could not enable $name"
        say "enabled $name (Woodpecker made the GitHub webhook)"
    fi

    # A fork's pull request must never run on this machine (P147e): no pull requests at all, and
    # approval for forks as a second line of defence. Trusted: the cache volume (all workflows),
    # and the Docker socket and the host network (Jepsen). Not security: no step is privileged (decision O4).
    api PATCH "/repos/$id" '{
        "allow_pr": false,
        "require_approval": "forks",
        "timeout": 360,
        "trusted": {"volumes": true, "network": true, "security": false}
    }' >/dev/null || fail "the server refused the settings (Trusted needs a Woodpecker admin's token)"

    local got
    got=$(api GET "/repos/$id")
    jq -e '.allow_pr == false and .require_approval == "forks" and .timeout == 360
           and .trusted.volumes and .trusted.network and (.trusted.security | not)' <<<"$got" >/dev/null ||
        fail "the settings did not all take; the server has: $(jq -c '{allow_pr, require_approval, timeout, trusted}' <<<"$got")"
    say "OK repo $name (id $id): pull requests off, approval for forks, 360 min, trusted for volumes and network only"
}

case "${1:-}" in
host) host ;;
repo) repo "${2:-}" ;;
*) fail "usage: nerva-woodpecker.sh host | repo OWNER/NAME" ;;
esac
