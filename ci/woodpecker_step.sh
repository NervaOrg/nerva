#!/usr/bin/env bash
# A Woodpecker step: prepares a plain ubuntu:24.04 container as GitHub's runner would be, then runs
# `ci/job.sh JOB [ARG]` as an unprivileged user. Run as root from the workspace (.woodpecker/*.yaml).
#
#   - Markdown alone (ci/changes.sh) runs nothing and passes (N68).
#   - The job runs as the user `ci`, not root, as on GitHub's runners: a test that expects
#     "permission denied" must not pass as root.
#   - /cache is the host's /var/cache/nerva-ci, shared by every job on the box (the repository must
#     be Trusted for the volume): the pinned toolchain (ci/install_zig.sh), Zig's global cache and
#     one project cache for every job and branch (ZIG_LOCAL_CACHE_DIR), so the nine workflows that
#     build the same nerva compile it once: Zig locks each manifest, and a second build of the
#     same artifact waits for the first and reuses it. Tests' own scratch stays in the workspace's
#     .zig-cache/tmp. Every job holds a shared lock on /cache/.lock while it runs; below
#     CI_FREE_MIN_GIB free (default 40), a job that gets the lock alone empties the caches first,
#     never the pinned toolchain.
#   - Each job has GitHub's timeout (ci.yml's timeout-minutes), so a hang ends the same way.
set -euo pipefail

job="${1:?usage: ci/woodpecker_step.sh <job> [arg]}"
arg="${2:-}"
cache=/cache
user=ci
free_min_gib="${CI_FREE_MIN_GIB:-40}"

case "$job" in
    integration) minutes=45 ;;
    unit | vopr | vopr-main | jepsen) minutes=60 ;;
    fuzz-long | vopr-long) minutes=330 ;;
    *) minutes=30 ;;
esac

export DEBIAN_FRONTEND=noninteractive
apt-get -o Acquire::Retries=5 update -qq
# What GitHub's ubuntu-24.04 runner has and the scripts use (unzip: .github/scripts/mac_zip_check.sh;
# gnupg2: rpmsign runs /usr/bin/gpg2, which only that package links to gpg).
apt-get -o Acquire::Retries=5 install -y -qq --no-install-recommends ca-certificates curl git \
    xz-utils python3 openssl procps iproute2 gnupg gnupg2 unzip zip jq file >/dev/null
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

# Nerva's IO is io_uring. Docker's default seccomp profile refuses it (Docker 25 and later), and a
# replica then exits 70 with its reason in a log the tests discard: say so here instead.
python3 - <<'EOF' || exit 1
import ctypes, os, sys
libc = ctypes.CDLL(None, use_errno=True)
params = ctypes.create_string_buffer(120)  # struct io_uring_params
fd = libc.syscall(425, 1, params)  # io_uring_setup, the same number on x86_64 and aarch64
if fd < 0:
    err = ctypes.get_errno()
    sys.exit(f"error: io_uring is refused here ({os.strerror(err)}): the step must be privileged "
             "(.woodpecker/*.yaml), or the host has kernel.io_uring_disabled set")
os.close(fd)
EOF

case "$job" in check | check-scripts) ci/install_repo_tools.sh ;; esac

id "$user" >/dev/null 2>&1 || useradd --create-home --uid 1001 --user-group "$user"
chown -R "$user:$user" "$PWD"
[ -d "$cache" ] || { echo "error: $cache is not mounted (see ops/ci/README.md, 'Nerva on Woodpecker')" >&2; exit 1; }
chown "$user:$user" "$cache"
touch "$cache/.lock"
chown "$user:$user" "$cache/.lock"
if [ "$job" = jepsen ]; then
    # The job still runs as `ci`: root would leave root's files in the shared Zig cache. The
    # socket's group lets it reach Docker, which is root on the host in all but name.
    sock=/var/run/docker.sock
    [ -S "$sock" ] || { echo "error: $sock is not mounted (see .woodpecker/jepsen.yaml)" >&2; exit 1; }
    gid=$(stat -c %g "$sock")
    getent group "$gid" >/dev/null || groupadd --gid "$gid" dockerhost
    usermod -aG "$(getent group "$gid" | cut -d: -f1)" "$user"
fi

exec 9<"$cache/.lock"
if [ "$(df --output=avail -B1G "$cache" | tail -1 | tr -d ' ')" -lt "$free_min_gib" ]; then
    if flock -x -n 9; then
        echo "Below $free_min_gib GiB free: emptying Zig's caches (no other job holds them)"
        toolchain="zig-$(sha256sum zig/download.sh | cut -c1-16)"
        rm -rf "$cache/zig" "$cache/zig-local" "$cache"/local-*
        find "$cache/nerva-toolchain" -mindepth 1 -maxdepth 1 ! -name "$toolchain" \
            -exec rm -rf {} + 2>/dev/null || true
    else
        echo "warning: below $free_min_gib GiB free, but other jobs hold the cache; not pruned" >&2
    fi
fi
flock -s 9
if [ "$job" = jepsen ]; then
    # run.sh's containers, network and subnet have fixed names: one run at a time on a machine.
    # Each run's store and memory record stay here for 14 days (GitHub keeps its artifacts as long).
    install -d -o "$user" -g "$user" "$cache/jepsen"
    touch "$cache/jepsen/.lock"
    exec 8<"$cache/jepsen/.lock"
    echo "jepsen: waiting for any other Jepsen run on this machine"
    flock -x 8
    find "$cache/jepsen" -mindepth 1 -maxdepth 1 -type d -mtime +14 -exec rm -rf {} +
    # Docker's static client, pinned: only the `docker` binary of the release archive, kept in the
    # cache (the archive is 82 MB). The Jepsen lock above makes this the only writer.
    docker_version=29.9.3
    docker_sha256=3fb5d1f13014c18cc54945bc177c58a9056a482dada031e17d12cf2e6922c973
    docker_cli="$cache/tools/docker-$docker_version"
    if [ ! -x "$docker_cli/docker" ]; then
        [ "$(uname -m)" = x86_64 ] || { echo "error: the pinned Docker client is x86_64; this is $(uname -m)" >&2; exit 1; }
        rm -rf "$docker_cli.partial"
        mkdir -p "$docker_cli.partial"
        curl -fsSL --retry 3 -o "$docker_cli.partial/docker.tgz" \
            "https://download.docker.com/linux/static/stable/x86_64/docker-$docker_version.tgz"
        echo "$docker_sha256  $docker_cli.partial/docker.tgz" | sha256sum -c - >/dev/null ||
            { echo "error: docker-$docker_version.tgz does not match its pinned sha256" >&2; exit 1; }
        tar --no-same-owner -xzf "$docker_cli.partial/docker.tgz" -C "$docker_cli.partial" --strip-components=1 docker/docker
        rm "$docker_cli.partial/docker.tgz"
        mv "$docker_cli.partial" "$docker_cli"
    fi
    ln -sf "$docker_cli/docker" /usr/local/bin/docker
    export JEPSEN_OUT="$cache/jepsen/$(date -u +%Y%m%dT%H%M%SZ)-${CI_PIPELINE_NUMBER:-local}"
    install -d -o "$user" -g "$user" "$JEPSEN_OUT"
    echo "jepsen: the store and memory record go to /var/cache/nerva-ci/${JEPSEN_OUT#"$cache"/} on the host"
fi
df -h "$cache" . | sed 's/^/  /'

as_ci() {
    setpriv --reuid "$user" --regid "$user" --init-groups \
        env HOME="/home/$user" USER="$user" XDG_CACHE_HOME="$cache" CI_CACHE_SHARED=1 \
        ZIG_LOCAL_CACHE_DIR="$cache/zig-local" "$@"
}

as_ci ci/install_zig.sh
status=0
as_ci timeout --kill-after=60 "$((minutes * 60))" ci/job.sh "$job" ${arg:+"$arg"} || status=$?
[ "$status" != 124 ] || echo "error: $job ran past its $minutes minutes" >&2

exit "$status"
