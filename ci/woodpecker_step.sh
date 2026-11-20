#!/usr/bin/env bash
# A Woodpecker step: prepares a plain ubuntu:24.04 container as GitHub's runner would be, then runs
# `ci/job.sh JOB [ARG]` as an unprivileged user. Run as root from the workspace (.woodpecker/*.yaml).
# The step is not privileged and has Docker's default capabilities only (decision O4): io_uring
# needs the host Docker daemon's seccomp profile (ops/ci/docker/README.md), not extra privilege.
#
#   - Markdown alone (ci/changes.sh) runs nothing and passes (N68).
#   - The job runs as the user `ci`, not root, as on GitHub's runners: a test that expects
#     "permission denied" must not pass as root.
#   - /cache holds the host's /var/cache/nerva-ci, laid out and enforced as ci/cache.sh says:
#     main/ is written by pipelines for main only (the YAML mounts it :ro for any other branch);
#     a branch has its own caches under branches/, a copy of main's when created, bounded and
#     pruned. Every job holds a shared lock on main/.lock; below CI_FREE_MIN_GIB free (default 60),
#     a main job waits up to CI_PRUNE_WAIT seconds (600) to hold it alone and empties main's Zig
#     caches (never the pinned toolchain), and a branch job empties the branch caches nobody uses.
#   - Each job has a timeout (75 minutes; 330 for the long searches), see the `case` below.
set -euo pipefail

job="${1:?usage: ci/woodpecker_step.sh <job> [arg]}"
arg="${2:-}"
cache=/cache
user=ci
free_min_gib="${CI_FREE_MIN_GIB:-60}"
branch="${CI_COMMIT_BRANCH:-}"
# Only a push to main is "main": the YAML picks the step, and so the mounts, by the same test.
role=branch
{ [ "${CI_PIPELINE_EVENT:-}" = push ] && [ "$branch" = main ]; } && role=main

# The step's timeout. ci.yml's jobs have 30 to 60 minutes on a runner of their own; here the
# package repositories' tests alone take about 23 minutes on an idle box, and a push runs 16
# workflows at once with the fleet beside them (pipeline 12's check-scripts and targets ended at
# the old 30). The search jobs run for MINUTES (at most 300) and then some.
case "$job" in
    fuzz-long | vopr-long) minutes=330 ;;
    *) minutes=75 ;;
esac

export DEBIAN_FRONTEND=noninteractive
apt-get -o Acquire::Retries=5 update -qq
# What GitHub's ubuntu-24.04 runner has and the scripts use (unzip: .github/scripts/mac_zip_check.sh;
# gnupg2: rpmsign runs /usr/bin/gpg2, which only that package links to gpg).
apt-get -o Acquire::Retries=5 install -y -qq --no-install-recommends ca-certificates curl git \
    xz-utils python3 openssl procps iproute2 gnupg gnupg2 unzip zip jq file util-linux >/dev/null
# Jepsen drives the host's Docker (the socket is mounted; the client is below) with a JDK, gnuplot
# and ssh-keygen.
[ "$job" != jepsen ] || apt-get -o Acquire::Retries=5 install -y -qq --no-install-recommends \
    openjdk-21-jdk-headless gnuplot-nox openssh-client >/dev/null
git config --global --add safe.directory "$PWD"

code=$(ci/changes.sh)
echo "changes: code=$code"
if [ "$code" = false ]; then
    echo "Markdown alone: nothing to prove, $job passes without running (N68)."
    exit 0
fi

ci/io_uring_check.sh

case "$job" in check | check-scripts | check-packages) ci/install_repo_tools.sh ;; esac

. ci/cache.sh
id "$user" >/dev/null 2>&1 || useradd --create-home --uid 1001 --user-group "$user"
chown -R "$user:$user" "$PWD"
ci_cache_check "$role" "$cache" || exit 1
[ -d "$cache" ] || { ci_error "NRV-E1202: $cache is not mounted"; exit 1; }

# One Jepsen run at a time on a machine: run.sh's containers, network and subnet have fixed names.
# Taken before the cache lock, so a queued run does not hold up a prune, and bounded. Each run's
# store and memory record stay under /cache/jepsen for 14 days (GitHub keeps its artifacts as long).
if [ "$job" = jepsen ]; then
    [ -d "$cache/jepsen" ] || { ci_error "NRV-E1202: $cache/jepsen is not mounted: mount /var/cache/nerva-ci/jepsen"; exit 1; }
    sock=/var/run/docker.sock
    [ -S "$sock" ] || { ci_error "NRV-E1203: $sock is not mounted (see .woodpecker/jepsen.yaml)"; exit 1; }
    install -d -o "$user" -g "$user" "$cache/jepsen"
    touch "$cache/jepsen/.lock"
    exec 8<"$cache/jepsen/.lock"
    echo "jepsen: waiting for any other Jepsen run on this machine"
    flock -x -w "${CI_JEPSEN_WAIT:-5400}" 8 || {
        ci_error "NRV-E1209: another Jepsen run held this machine for ${CI_JEPSEN_WAIT:-5400} s: start this one again when it ends"
        exit 1
    }
    find "$cache/jepsen" -mindepth 1 -maxdepth 1 -type d -mtime +14 -exec rm -rf {} +
    # The job still runs as `ci`: root would leave root's files in the cache. The socket's group
    # lets it reach Docker, which is root on the host in all but name (decision O4).
    gid=$(stat -c %g "$sock")
    getent group "$gid" >/dev/null || groupadd --gid "$gid" dockerhost
    usermod -aG "$(getent group "$gid" | cut -d: -f1)" "$user"
    # Docker's static client, pinned: its archive is kept in the jepsen cache, checked on every use.
    ci/docker_client.sh 29.9.3 3fb5d1f13014c18cc54945bc177c58a9056a482dada031e17d12cf2e6922c973 "$cache/jepsen/tools"
    export JEPSEN_OUT="$cache/jepsen/$(date -u +%Y%m%dT%H%M%SZ)-${CI_PIPELINE_NUMBER:-local}"
    install -d -o "$user" -g "$user" "$JEPSEN_OUT"
    echo "jepsen: the store and memory record go to /var/cache/nerva-ci/${JEPSEN_OUT#"$cache"/} on the host"
fi

low=no
[ "$(df --output=avail -B1G "$cache" | tail -1 | tr -d ' ')" -ge "$free_min_gib" ] || low=yes
if [ "$role" = main ]; then
    touch "$cache/main/.lock"
    chown "$user:$user" "$cache/main/.lock"
    install -d -o "$user" -g "$user" "$cache/main/zig" "$cache/main/zig-local" "$cache/main/tools"
    exec 9<"$cache/main/.lock"
    [ "$low" = no ] || { echo "Below $free_min_gib GiB free"; ci_main_prune "$cache"; }
    flock -s 9
    base="$cache/main"
    toolchain_write=1
else
    # main's cache is read-only here; this branch's own is a copy of it, made under main's lock.
    if [ -e "$cache/main/.lock" ]; then exec 9<"$cache/main/.lock"; flock -s 9; fi
    [ "$low" = no ] || { echo "Below $free_min_gib GiB free: emptying the branch caches nobody uses"; export CI_BRANCH_PRUNE_ALL=1; }
    ci_branch_prepare "$cache" "$branch"
    flock -u 9 2>/dev/null || true
    base="$CI_BRANCH_DIR"
    chown "$user:$user" "$base" "$base/zig" "$base/zig-local"
    toolchain_write=0
fi
df -h "$cache" . | sed 's/^/  /'

as_ci() {
    setpriv --reuid "$user" --regid "$user" --init-groups \
        env HOME="/home/$user" USER="$user" CI_CACHE_SHARED=1 \
        ZIG_GLOBAL_CACHE_DIR="$base/zig" ZIG_LOCAL_CACHE_DIR="$base/zig-local" \
        CI_TOOLCHAIN_DIR="$cache/main/tools" CI_TOOLCHAIN_WRITE="$toolchain_write" "$@"
}

as_ci ci/install_zig.sh
status=0
as_ci timeout --kill-after=60 "$((minutes * 60))" ci/job.sh "$job" ${arg:+"$arg"} || status=$?
[ "$status" != 124 ] || echo "error: $job ran past its $minutes minutes" >&2

exit "$status"
