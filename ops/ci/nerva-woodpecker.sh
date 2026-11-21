#!/usr/bin/env bash
# Nerva's part of the Woodpecker setup, after woodpecker-bootstrap.sh (README.md, "Nerva on
# Woodpecker"). Two modes:
#
#   `host` runs on the box, as root, from ~ (after `scp -r ops/ci root@BOX:`, which puts the
#   directory at ~/ci/ on the box), on every agent box:
#     bash ci/nerva-woodpecker.sh host
#   Checks Docker (and that its daemon carries the io_uring seccomp profile, which
#   woodpecker-bootstrap.sh installs), /dev/fuse and /dev/kvm, and creates the cache directories
#   under /var/cache/nerva-ci (main, branches, jepsen and locks: decision O4), all root-owned, mode
#   0755 (a box from before that, whose roots a job owned, is converted by running it again).
#
#   `repo` runs from the repository root, on your laptop (needs curl and jq), with a personal
#   token from Woodpecker (your avatar, then Personal access token):
#     WOODPECKER_SERVER=https://ci.example.org WOODPECKER_TOKEN=... bash ops/ci/nerva-woodpecker.sh repo OWNER/NAME
#   Enables the repository if it is not yet, then sets: pull requests off, approval for forks,
#   a 360-minute timeout, and Trusted for volumes and network (not security: no step is
#   privileged, decision O4). It reads the settings back and fails if any did not take.
#
# Both modes can run again: each only changes what is not yet as it should be. The last line is
# `nerva-woodpecker: OK ...` or `nerva-woodpecker: FAIL NRV-E12xx: ...` (docs/ERRORS.md, 12xx).
#
# Where `host` looks, for ci/ci_test.sh (which runs it with stubs): NERVA_CI_CACHE_ROOT (default
# /var/cache/nerva-ci), NERVA_CI_DEV (/dev) and NERVA_CI_MODULES_DIR (/etc/modules-load.d).
set -euo pipefail

fail() { echo "nerva-woodpecker: FAIL $*" >&2; exit 1; }
say() { echo "nerva-woodpecker: $*"; }

host() {
    local probe msg root dev modules
    root="${NERVA_CI_CACHE_ROOT:-/var/cache/nerva-ci}"
    dev="${NERVA_CI_DEV:-/dev}"
    modules="${NERVA_CI_MODULES_DIR:-/etc/modules-load.d}"
    [ "$(id -u)" = 0 ] || fail "NRV-E1221: run as root: ssh -t root@BOX bash ci/nerva-woodpecker.sh host"
    probe="$(dirname "$(readlink -f "$0")")/io_uring_probe.sh"
    [ -f "$probe" ] ||
        fail "NRV-E1213: $probe is missing: run it from a copy of ops/ci/ that has io_uring_probe.sh beside it (scp -r ops/ci root@BOX:, then bash ci/nerva-woodpecker.sh host)"
    command -v docker >/dev/null || fail "NRV-E1216: no docker: run ci/woodpecker-bootstrap.sh on this box first"
    docker info >/dev/null 2>&1 || fail "NRV-E1216: docker is installed but not running: systemctl status docker"
    docker ps --format '{{.Names}}' | grep -q woodpecker-agent ||
        fail "NRV-E1216: no woodpecker-agent container: run ci/woodpecker-bootstrap.sh (or its agent mode) first"

    # Jepsen's LazyFS mounts FUSE inside the node containers.
    [ -e "$dev/fuse" ] || modprobe fuse 2>/dev/null || true
    [ -e "$dev/fuse" ] || fail "NRV-E1217: /dev/fuse is missing and \`modprobe fuse\` did not add it: install the host's fuse module (Jepsen's LazyFS needs it)"
    echo fuse > "$modules/nerva-ci.conf"

    if [ -e "$dev/kvm" ]; then
        say "/dev/kvm present"
    else
        say "warning: no /dev/kvm (enable virtualisation in the BIOS); Nerva's workflows do not need it yet"
    fi

    # No step is privileged, so io_uring needs the daemon's own profile (ops/ci/docker/README.md).
    msg=$(bash "$probe" 2>&1) || fail "$msg" # the probe's own NRV-E1201, E1211 or E1212

    # The caches the workflows mount (.woodpecker/*.yaml). main/ is written only by pipelines for a
    # push to main, which mount it writable; the others mount it read-only and write branches/.
    # jepsen/ keeps each Jepsen run's store. Every mount root is ROOT's, mode 0755, no ACL (rule 1
    # of ci/cache.sh): the jobs (uid 1001, `ci`) own the directories a step makes directly in a root
    # and what is below them, never a root, so nothing a job does can make a root unusable for the
    # next pipeline. The steps make those directories (a link planted at a name would be followed
    # by `install -d` here), so none is made here. An earlier layout made the roots 1001's: this
    # converts them (a step does too, NRV-W1203, but only the roots it mounts).
    install -d -m 0755 -o 0 -g 0 "$root" "$root/main" "$root/branches" "$root/jepsen"
    # An ACL, a default one included, that a job set on a root while it owned it stays after the
    # chown: removed (setfacl is the acl package's).
    if command -v setfacl >/dev/null; then
        setfacl -b -k -- "$root" "$root/main" "$root/branches" "$root/jepsen" 2>/dev/null || true
    else
        say "warning: no setfacl (apt-get install acl): an ACL on a cache root cannot be removed here; steps remove it"
    fi
    # The lock files (main.lock, branches.lock, b-<key>.lock, jepsen.lock) live in a directory of
    # their own that the jobs (uid 1001) cannot write, so a lock file there cannot be replaced by a
    # job, and a step running as root would then follow its link.
    # Made root's (and, by install, set right again if a run left it otherwise); a step refuses one
    # a job could write (NRV-E1226).
    install -d -m 0700 -o 0 -g 0 "$root/locks"
    # What the first layout left (one shared cache for every branch) is no longer read. A plain
    # loop: on a fresh box none of them exists, which would fail an `ls` under pipefail.
    local old="" n
    for n in nerva-toolchain zig zig-local zig-cache; do
        [ ! -e "$root/$n" ] || old="$old$n "
    done
    [ -z "$old" ] || say "note: $root holds the old layout ($old); nothing reads it now, delete it when you like"
    local avail
    avail=$(df --output=avail -B1G "$root" | tail -1 | tr -d ' ')
    [ "$avail" -ge 100 ] ||
        say "warning: only $avail GiB free under $root; a push runs 15 workflows, the integration one alone takes 3.5 GiB"

    local cpus mem
    cpus=$(nproc)
    mem=$(awk '/^MemTotal:/ {print int($2 / 1048576)}' /proc/meminfo)
    say "OK host $(hostname): $cpus CPUs, $mem GiB, $avail GiB free for $root"
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
    [[ "$name" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || fail "NRV-E1221: usage: bash ops/ci/nerva-woodpecker.sh repo OWNER/NAME"
    : "${WOODPECKER_SERVER:?set WOODPECKER_SERVER, e.g. https://ci.example.org}"
    : "${WOODPECKER_TOKEN:?set WOODPECKER_TOKEN (Woodpecker: your avatar, then Personal access token)}"
    command -v jq >/dev/null || fail "NRV-E1221: needs jq"
    api GET /user >/dev/null || fail "NRV-E1218: the server or the token was refused: check WOODPECKER_SERVER and WOODPECKER_TOKEN"

    local id
    if ! id=$(api GET "/repos/lookup/$name" 2>/dev/null | jq -er .id); then
        # Not enabled yet: find it among the forge's repositories this user can see.
        local remote
        remote=$(api GET '/user/repos?all=true' |
            jq -er --arg n "$name" '.[] | select(.full_name == $n) | .forge_remote_id') ||
            fail "NRV-E1219: $name is not among your forge's repositories as Woodpecker sees them (are you an admin of it?)"
        id=$(api POST "/repos?forge_remote_id=$remote" | jq -er .id) || fail "NRV-E1219: could not enable $name: the server refused it (an admin's token enables a repository)"
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
    }' >/dev/null || fail "NRV-E1220: the server refused the settings (Trusted needs a Woodpecker admin's token)"

    local got
    got=$(api GET "/repos/$id")
    jq -e '.allow_pr == false and .require_approval == "forks" and .timeout == 360
           and .trusted.volumes and .trusted.network and (.trusted.security | not)' <<<"$got" >/dev/null ||
        fail "NRV-E1220: the settings did not all take; the server has: $(jq -c '{allow_pr, require_approval, timeout, trusted}' <<<"$got")"
    say "OK repo $name (id $id): pull requests off, approval for forks, 360 min, trusted for volumes and network only"
}

# reset_cache WHAT: empties one cache at once (the operator's answer to what a step's normalization
# does not promise: a job's damage to the content or the type of something deep in its own cache,
# which a branch's prune clears in 7 days and main's only when the disk is low). WHAT is `main`
# (main's zig and zig-local; never tools, the pinned toolchain) or a branch name (that branch's
# directory). It is the operation of the prune and of NRV-W1204: `rm -rf --one-file-system` of a
# DIRECT child of a mount root that this user (root) owns and no one else can write, which never
# follows a link, under the exclusive lock that keeps the pipelines out (main's lock, or the
# branch's own; steps hold them shared while they run) and the children lock (so that no step is
# in the middle of making the directory). The next pipeline makes the directories again.
reset_cache() {
    local what="${1:-}" root mount lock key safe sum wait names=() n
    [ -n "$what" ] && [ $# -le 1 ] || fail "NRV-E1221: usage: bash ci/nerva-woodpecker.sh reset-cache main|BRANCH"
    root="${NERVA_CI_CACHE_ROOT:-/var/cache/nerva-ci}"
    wait="${NERVA_CI_RESET_WAIT:-60}"
    [[ "$wait" =~ ^[0-9]{1,5}$ ]] || fail "NRV-E1221: NERVA_CI_RESET_WAIT='$wait' is not a whole number of seconds"
    if [ "$what" = main ]; then
        mount="$root/main"
        lock="$root/locks/main.lock"
        names=(zig zig-local)
    else
        # The key of ci/cache.sh's ci_branch_key (a test keeps the two equal).
        safe=$(printf '%s' "$what" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-48)
        sum=$(printf '%s' "$what" | sha256sum | cut -c1-8)
        key="b-$safe-$sum"
        mount="$root/branches"
        lock="$root/locks/$key.lock"
        names=("$key")
    fi
    # Only a mount root that is this user's and that no one else can write: in it, a name is not
    # something a job could have swapped for a link between the test and the rm.
    if [ -L "$mount" ] || [ ! -d "$mount" ] || [ "$(stat -c %u "$mount")" != "$(id -u)" ] || [ -n "$(find "$mount" -maxdepth 0 -perm /022)" ] ||
        [ -L "$root/locks" ] || [ ! -d "$root/locks" ] || [ "$(stat -c %u "$root/locks")" != "$(id -u)" ] || [ -n "$(find "$root/locks" -maxdepth 0 -perm /077)" ]; then
        fail "NRV-E1235: $mount and $root/locks must be real directories owned by $(id -un), not writable by anyone else (the locks one mode 0700): run bash ci/nerva-woodpecker.sh host first"
    fi
    local f
    for f in "$lock" "$root/locks/$(basename "$mount")-children.lock"; do
        if [ -L "$f" ] || { [ -e "$f" ] && [ ! -f "$f" ]; }; then fail "NRV-E1235: $f is not a regular file: remove it"; fi
        [ -e "$f" ] || (umask 077 && set -C && : >"$f") 2>/dev/null || true
    done
    (
        exec 8>>"$lock" 4>>"$root/locks/$(basename "$mount")-children.lock" || exit 4
        flock -x -w "$wait" 8 || exit 3
        flock -x -w "$wait" 4 || exit 3
        for n in "${names[@]}"; do
            [ -e "$mount/$n" ] || [ -L "$mount/$n" ] || continue
            rm -rf --one-file-system -- "${mount:?}/$n" || exit 5
            { [ ! -e "$mount/$n" ] && [ ! -L "$mount/$n" ]; } || exit 5
            echo "nerva-woodpecker: removed $mount/$n"
        done
    ) || case "$?" in
        3) fail "NRV-E1235: $what's cache is in use: pipelines hold its lock (shared, while a step runs) and none let go in $wait s: wait for them, or stop them in Woodpecker, then run this again (NERVA_CI_RESET_WAIT raises the wait)" ;;
        5) fail "NRV-E1235: a cache directory of $what under $mount could not be removed (a mount inside it?): look at it with ls -la and remove what is in the way" ;;
        *) fail "NRV-E1235: the lock files under $root/locks could not be opened" ;;
    esac
    say "OK reset-cache $what: the next pipeline makes its cache directories again"
}

case "${1:-}" in
host) host ;;
repo) repo "${2:-}" ;;
reset-cache) shift; reset_cache "$@" ;;
*) fail "NRV-E1221: usage: bash ci/nerva-woodpecker.sh host (on the box) | bash ci/nerva-woodpecker.sh reset-cache main|BRANCH (on the box) | bash ops/ci/nerva-woodpecker.sh repo OWNER/NAME (from the repository root)" ;;
esac
