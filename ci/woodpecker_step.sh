#!/usr/bin/env bash
# A Woodpecker step: prepares a plain ubuntu:24.04 container as GitHub's runner would be, then runs
# `ci/job.sh JOB [ARG]` as an unprivileged user. Run as root from the workspace (.woodpecker/*.yaml).
#
#   - Markdown alone (ci/changes.sh) runs nothing and passes (N68).
#   - The job runs as the user `ci`, not root, as on GitHub's runners: a test that expects
#     "permission denied" must not pass as root.
#   - /cache is the host's /var/cache/nerva-ci, shared by every job on the box (the repository must
#     be Trusted for the volume): the pinned toolchain (ci/install_zig.sh), Zig's global cache and,
#     per job, a copy of .zig-cache that only a push to main that passed saves. Every job holds a
#     shared lock on /cache/.lock while it runs; below CI_FREE_MIN_GIB free (default 40), a job
#     that gets the lock alone empties the caches first, never the pinned toolchain.
#   - Each job has GitHub's timeout (ci.yml's timeout-minutes), so a hang ends the same way.
set -euo pipefail

job="${1:?usage: ci/woodpecker_step.sh <job> [arg]}"
arg="${2:-}"
cache=/cache
user=ci
free_min_gib="${CI_FREE_MIN_GIB:-40}"

case "$job" in
    integration) minutes=45 ;;
    unit | vopr | vopr-main) minutes=60 ;;
    *) minutes=30 ;;
esac

export DEBIAN_FRONTEND=noninteractive
apt-get -o Acquire::Retries=5 update -qq
apt-get -o Acquire::Retries=5 install -y -qq --no-install-recommends ca-certificates curl git \
    xz-utils python3 openssl procps iproute2 gnupg >/dev/null
git config --global --add safe.directory "$PWD"

code=$(ci/changes.sh)
echo "changes: code=$code"
if [ "$code" = false ]; then
    echo "Markdown alone: nothing to prove, $job passes without running (N68)."
    exit 0
fi

[ "$job" != check ] || ci/install_repo_tools.sh

id "$user" >/dev/null 2>&1 || useradd --create-home --uid 1001 --user-group "$user"
chown -R "$user:$user" "$PWD"
[ -d "$cache" ] || { echo "error: $cache is not mounted (see ops/ci/README.md, 'Nerva on Woodpecker')" >&2; exit 1; }
chown "$user:$user" "$cache"
touch "$cache/.lock"
chown "$user:$user" "$cache/.lock"

local_key="local-$job${arg:+-$arg}"
exec 9<"$cache/.lock"
if [ "$(df --output=avail -B1G "$cache" | tail -1 | tr -d ' ')" -lt "$free_min_gib" ]; then
    if flock -x -n 9; then
        echo "Below $free_min_gib GiB free: emptying Zig's caches (no other job holds them)"
        toolchain="zig-$(sha256sum zig/download.sh | cut -c1-16)"
        rm -rf "$cache/zig" "$cache"/local-*
        find "$cache/nerva-toolchain" -mindepth 1 -maxdepth 1 ! -name "$toolchain" \
            -exec rm -rf {} + 2>/dev/null || true
    else
        echo "warning: below $free_min_gib GiB free, but other jobs hold the cache; not pruned" >&2
    fi
fi
flock -s 9
df -h "$cache" . | sed 's/^/  /'

as_ci() {
    setpriv --reuid "$user" --regid "$user" --init-groups \
        env HOME="/home/$user" USER="$user" XDG_CACHE_HOME="$cache" CI_CACHE_SHARED=1 "$@"
}

if [ -d "$cache/$local_key" ]; then
    as_ci cp -a "$cache/$local_key/." .zig-cache/ 2>/dev/null || as_ci mkdir -p .zig-cache
    echo "zig-cache: restored $(du -sm .zig-cache | cut -f1) MB from $local_key"
fi

as_ci ci/install_zig.sh
status=0
as_ci timeout --kill-after=60 "$((minutes * 60))" ci/job.sh "$job" ${arg:+"$arg"} || status=$?
[ "$status" != 124 ] || echo "error: $job ran past its $minutes minutes" >&2

. ci/lib.sh
if [ "$status" = 0 ] && ci_on_main_push; then
    # What tests and demos write under .zig-cache is the state of one run, never saved. The copy
    # is made aside and renamed in; the copy it replaces is removed only by the next save, so a
    # job still restoring from it reads it whole.
    as_ci rm -rf .zig-cache/tmp
    as_ci rm -rf "$cache/$local_key.new.$$" "$cache/$local_key".old.*
    as_ci cp -a .zig-cache "$cache/$local_key.new.$$"
    [ ! -d "$cache/$local_key" ] || as_ci mv "$cache/$local_key" "$cache/$local_key.old.$$"
    as_ci mv "$cache/$local_key.new.$$" "$cache/$local_key"
    echo "zig-cache: saved $(du -sm "$cache/$local_key" | cut -f1) MB as $local_key"
fi
exit "$status"
