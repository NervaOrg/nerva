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
#     the roots (main/, branches/, jepsen/) are root's, mode 0755, never the job's; root makes the
#     directories directly in them and hands them to `ci`, and resets one `ci` cannot use;
#     main/ is written by pipelines for main only (the YAML mounts it :ro for any other branch);
#     a branch has its own caches under branches/, zig/p seeded from main's when created, bounded and
#     pruned. Every job holds a shared lock on locks/main.lock (the lock directory, root's, which a job cannot write); below CI_FREE_MIN_GIB free (default 60),
#     a main job waits up to CI_PRUNE_WAIT seconds (5) to hold it alone, measures free space again, and if still low
#     empties main's Zig caches (never the pinned toolchain), and a branch job empties the branch caches nobody uses.
#     "Low" is blocks (CI_FREE_MIN_GIB) or inodes (CI_MIN_FREE_INODES, default 100000: a job's empty files
#     cost none). Nothing here walks a job's tree under a lock others wait on: a drop is a rename into the
#     mount root's root-only .trash (ci/cache.sh, the design rule) and the trash is emptied after the lock
#     is released, by one step at a time, a bounded time (CI_TRASH_SECONDS), before the job (and
#     BEFORE "low" is measured: a trash the last step left still holds the blocks and inodes that
#     made the disk look low) and again after it, for the tail (CI_TRASH_TAIL_SECONDS, never past the
#     repository's timeout: CI_REPO_TIMEOUT_MINUTES); a branch's size is a record its own step writes after its locks, before the job and
#     after it (CI_BRANCH_DU_SECONDS).
#   - The short jobs hold a shared lock on locks/box.lock around their run alone, the integration job
#     an exclusive one around its timed scenario alone (every other scenario is a shared run before),
#     behind a turnstile (locks/turnstile.lock) so shared jobs cannot starve it: that scenario runs
#     with no other short job's run beside it. The long jobs (fuzz-long, vopr-long, jepsen) take no lock and integration does not
#     wait for them (decision O12, ci_box_lock; CI_BOX_WAIT, NRV-E1245).
#   - Each job has a timeout (75 minutes; 330 for the long searches; CI_STEP_MINUTES replaces it),
#     see the `case` below; one that runs past it fails NRV-E1215.
set -euo pipefail
. ci/lib.sh
# When this step began (epoch seconds): the post-job tail never runs past the repository's timeout
# (ci_tail_seconds in ci/cache.sh).
# shellcheck disable=SC2034 # read by ci/cache.sh (ci_tail_seconds, ci_job_seconds)
CI_STEP_START=$(date +%s)

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
# CI_STEP_MINUTES (a pipeline variable) replaces it for a run.
minutes="${CI_STEP_MINUTES:-$minutes}"
[[ "$minutes" =~ ^[1-9][0-9]*$ ]] || { ci_error "NRV-E1208: CI_STEP_MINUTES='$minutes' is not a whole number of minutes"; exit 2; }
# The scripts' own tests (check-scripts, run as root before the job) take about 4 to 5 minutes as
# root (about 3.5 as another user); a hang there is bounded on its own (20 minutes, as ci.yml's job),
# not by the job's whole limit. CI_SCRIPTS_TEST_MINUTES replaces it.
test_minutes="${CI_SCRIPTS_TEST_MINUTES:-20}"
[[ "$test_minutes" =~ ^[1-9][0-9]*$ ]] || { ci_error "NRV-E1208: CI_SCRIPTS_TEST_MINUTES='$test_minutes' is not a whole number of minutes"; exit 2; }

# The box lock (decision O12, ci_box_lock in ci/cache.sh) is taken far below, around the job's run
# alone: never around the package install, the seed copy or the tail, and not at all by a Markdown-only
# run (N68), which exits before it (and before ci_locks_check, so that run never looks at locks/).
. ci/cache.sh
ci_knobs_check || exit 2

export DEBIAN_FRONTEND=noninteractive
apt-get -o Acquire::Retries=5 update -qq
# What GitHub's ubuntu-24.04 runner has and the scripts use (unzip: .github/scripts/mac_zip_check.sh;
# gnupg2: rpmsign runs /usr/bin/gpg2, which only that package links to gpg; acl: setfacl, which
# ci/cache.sh uses to remove the ACLs a job may have set on its caches).
apt-get -o Acquire::Retries=5 install -y -qq --no-install-recommends ca-certificates curl git \
    xz-utils python3 openssl procps iproute2 gnupg gnupg2 unzip zip jq file util-linux acl >/dev/null
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

# shellcheck disable=SC2034 # read by ci/cache.sh (ci_as_job)
CI_JOB_USER="$user" # ci_as_job: what root would make in a cache the job writes, the job's user makes
id "$user" >/dev/null 2>&1 || useradd --create-home --uid 1001 --user-group "$user"
chown -R "$user:$user" "$PWD"
ci_locks_check "$cache" || exit 1
ci_cache_check "$role" "$cache" || exit 1
# What an earlier step left in the trash of the mount this one writes is removed BEFORE the disk is
# measured: its blocks and inodes are what made the disk look low, and a step that measures first
# prunes caches that were fine (ci_trash_empty: one removal per mount at a time, none waits for
# another's, CI_TRASH_SECONDS at most). main's trash is the main role's to empty (a branch has it
# read-only), branches' the branch role's; the low-disk prunes' guard does not need the other:
# it reads the markers and locks in locks/ (ci_trash_pending). Not under the Jepsen lock below.
if [ "$role" = main ]; then ci_trash_empty "$cache/main"; else ci_trash_empty "$cache/branches"; fi

# One Jepsen run at a time on a machine: run.sh's containers, network and subnet have fixed names.
# Taken before the cache lock, so a queued run does not hold up a prune, and bounded. Each run's
# store and memory record stay under /cache/jepsen for 14 days (GitHub keeps its artifacts as long).
if [ "$job" = jepsen ]; then
    [ -d "$cache/jepsen" ] || { ci_error "NRV-E1202: $cache/jepsen is not mounted: mount /var/cache/nerva-ci/jepsen"; exit 1; }
    sock=/var/run/docker.sock
    [ -S "$sock" ] || { ci_error "NRV-E1203: $sock is not mounted (see .woodpecker/jepsen.yaml)"; exit 1; }
    # The mount's root is root's, mode 0755, no ACL (rule 1 of ci/cache.sh): made so if a job's
    # own doing or an earlier layout left it otherwise (NRV-W1203).
    ci_mount_root "$cache/jepsen" || exit 1
    ci_trash_empty "$cache/jepsen" # a leftover of an earlier run's sweep; before this run takes the lock others wait on
    ci_lock_file "$cache/locks/jepsen.lock" || exit 1
    { exec 8<"$cache/locks/jepsen.lock"; } 2>/dev/null || { ci_lock_open_failed "$cache/locks/jepsen.lock" '<'; exit 1; }
    echo "jepsen: waiting for any other Jepsen run on this machine"
    flock -x -w "${CI_JEPSEN_WAIT:-5400}" 8 || {
        ci_error "NRV-E1209: another Jepsen run held this machine for ${CI_JEPSEN_WAIT:-5400} s: start this one again when it ends"
        exit 1
    }
    # Run directories older than 14 days are moved aside here (ci_trash_move: a rename). Never
    # `tools` (ci_jepsen_sweep). The sweep wrote jepsen's marker, which holds the box-wide low-disk
    # prunes off (ci_trash_pending), so the trash is drained now, bounded by CI_TRASH_SECONDS, while
    # the lock is held, rather than after a Jepsen run of hours (review 6004714906); what is left is
    # removed by the tail below. A DELIBERATE EXCEPTION to "root never walks a job's tree under a lock
    # others wait on" (ci/cache.sh, rule 2; review 6004928827): this walks old run directories while
    # fd 8 is held, and another Jepsen step waits on fd 8 (CI_JEPSEN_WAIT, 5400 s), but it is bounded
    # by CI_TRASH_SECONDS (20 s), skipped if another step is already removing, and a Jepsen job is
    # root-equivalent through the Docker socket anyway.
    ci_jepsen_sweep "$cache/jepsen"
    ci_trash_empty "$cache/jepsen"
    # The job still runs as `ci`: root would leave root's files in the cache. The socket's group
    # lets it reach Docker, which is root on the host in all but name (decision O4).
    gid=$(stat -c %g "$sock")
    getent group "$gid" >/dev/null || groupadd --gid "$gid" dockerhost
    usermod -aG "$(getent group "$gid" | cut -d: -f1)" "$user"
    # Docker's static client, pinned: its archive is kept in the jepsen cache, checked on every use.
    # The download goes into the cache the job writes, so the job's user fetches it (a link at the
    # partial file's name is then not root's to write through); root only checks and unpacks it.
    # tools is a direct child of the jepsen root: made, or reset if unusable, by root (this run holds
    # the jepsen lock, fd 8, exclusively, which keeps every other run out).
    ci_child_ensure "$cache/jepsen/tools" "$cache/jepsen" || exit 1
    # A reset of tools moved the old one into jepsen/.trash (and wrote its marker): drained now, the
    # same exception and the same bound as the sweep's.
    ci_trash_empty "$cache/jepsen"
    docker_pin=(29.9.3 3fb5d1f13014c18cc54945bc177c58a9056a482dada031e17d12cf2e6922c973 "$cache/jepsen/tools")
    ci_as_job ci/docker_client.sh "${docker_pin[@]}" fetch
    ci/docker_client.sh "${docker_pin[@]}" install
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    export JEPSEN_OUT="$cache/jepsen/$stamp-${CI_PIPELINE_NUMBER:-local}"
    ci_child_make "$JEPSEN_OUT" || { ci_child_refused "$JEPSEN_OUT"; exit 1; }
    echo "jepsen: the store and memory record go to /var/cache/nerva-ci/${JEPSEN_OUT#"$cache"/} on the host"
fi

# main/ is mounted in every role (writable for main, :ro for a branch); /cache itself is only the
# container's own directory, so it would measure the container's filesystem, not the box's cache.
cache_fs="$cache/main"
low=no
# Low on blocks (CI_FREE_MIN_GIB) or on inodes (CI_MIN_FREE_INODES, default 100000): a job's empty
# files cost no blocks, and the branch's size bound counts blocks only.
if ci_disk_low "$cache_fs" "$free_min_gib"; then low=yes; fi
if [ "$role" = main ]; then
    ci_main_prepare "$cache" "$user" "$low" "$free_min_gib" || exit 1
    ci_shared_lock || exit 1
    base="$cache/main"
    toolchain_write=1
else
    # main's cache is read-only here; this branch's own is a copy of it, made under main's lock.
    ci_main_lock_open "$cache" || exit 1
    ci_shared_lock || exit 1
    [ "$low" = no ] || { echo "Below $free_min_gib GiB free: emptying the branch caches nobody uses"; export CI_BRANCH_PRUNE_ALL=1; }
    ci_branch_prepare "$cache" "$branch" || exit 1
    flock -u 9 2>/dev/null || true
    base="$CI_BRANCH_DIR" # made by root and handed to the job; its zig and zig-local by the job's user
    toolchain_write=0
fi
df -h "$cache_fs" . | sed 's/^/  /'

# The command prefix that runs something as `ci`, with the caches' environment.
as_ci=(setpriv --reuid "$user" --regid "$user" --init-groups
    env HOME="/home/$user" USER="$user" CI_CACHE_SHARED=1
    ZIG_GLOBAL_CACHE_DIR="$base/zig" ZIG_LOCAL_CACHE_DIR="$base/zig-local"
    CI_TOOLCHAIN_DIR="$cache/main/tools" CI_TOOLCHAIN_WRITE="$toolchain_write")

# The step's locks (fds 6 to 11) stay with the step: bash's `exec N<file` is not close-on-exec, so a
# job would inherit them and could `flock -x` one for good. Both commands close them for the child
# only; the step's own descriptors, and so its locks, stay open until it exits.
"${as_ci[@]}" ci/install_zig.sh 6>&- 7>&- 8>&- 9<&- 10<&- 11<&-
# The scripts' own tests run as root, here, before the job (review 6000930445): their guards on what
# root does (the uid spies, the ownership and mount tests) are vacuous, and say so, as anyone else.
# The checkout is this commit's and nothing untrusted has run in this step yet, as for the scripts
# above. Without CAP_SYS_ADMIN (this container's) their mount tests print a skip note. The job then
# skips its own run of them (CI_SCRIPTS_TESTED), and the step fails if either failed. The tests
# have a bound of their own, 20 minutes (CI_SCRIPTS_TEST_MINUTES).
# shellcheck disable=SC2034 # a nameref array: ci_step_run_with_tests reads it by name
tests_cmd=(bash ci/ci_test.sh)
# shellcheck disable=SC2034 # a nameref array, as above
job_cmd=("${as_ci[@]}" ci/job.sh "$job" ${arg:+"$arg"})
status=0
# The job's bound is the step's limit, or less when the pre-job phase took long enough that
# Woodpecker's repository timeout would cut it off (ci_job_seconds, NRV-W1207). For check-scripts the
# root tests run first and their whole bound (and its kill-after) is taken off what is left. With
# no time left (0) neither runs: NRV-E1215 said so, and the step fails.
reserved=0
if [ "$job" = check-scripts ]; then reserved=$((test_minutes * 60 + ${CI_KILL_AFTER:-60})); fi
# (ci_step_job and ci_step_run_with_tests are in ci/cache.sh and ci/lib.sh, with their tests: for
# check-scripts the root tests run first, bounded by CI_SCRIPTS_TEST_MINUTES, not by the job's whole
# limit; either failing fails the step. A job with no time left is not started, and a shortened one
# names the repository's Timeout in its NRV-E1215.) The tail below runs whatever the status.
# The box lock (decision O12; ci_step_job_in_box, ci_step_integration in ci/cache.sh, with their tests)
# covers the job's run alone and is let go before the tail. fuzz-long, vopr-long and jepsen are long
# jobs: they take no lock, so they never keep integration waiting (and integration's timing can suffer
# beside them: accepted, O12). integration runs every scenario but the timed one first
# (`ci/job.sh integration untimed`: a shared run, which also compiles), then the timed scenario alone
# (`ci/job.sh integration timed`), exclusive, bounded by CI_INTEGRATION_RUN_MINUTES, so what everyone
# waits for is a cluster start and 50 lookups and nothing else. A wait that fails (NRV-E1245) fails the step, which goes on to its tail.
case "$job" in
    fuzz-long | vopr-long | jepsen) box=none ;;
    integration) box=integration ;;
    *) box=shared ;;
esac
if [ "$box" = integration ]; then
    # shellcheck disable=SC2034 # nameref arrays, read by ci_step_run_with_tests
    untimed_cmd=("${as_ci[@]}" ci/job.sh integration untimed)
    # shellcheck disable=SC2034 # as above
    timed_cmd=("${as_ci[@]}" ci/job.sh integration timed)
    ci_step_integration "$cache/locks" "$minutes" "$reserved" "$((test_minutes * 60))" tests_cmd untimed_cmd timed_cmd || status=$?
else
    ci_step_job_in_box "$box" "$cache/locks" "$job" "$minutes" "$reserved" "$((test_minutes * 60))" tests_cmd job_cmd || status=$?
fi
# A Jepsen run holds the Jepsen lock exclusively for its whole run, so what is left of what its sweep
# and its reset of the tools moved aside (both were drained at once, a bounded 20 s each) is removed
# only now, after the lock is let go (nothing is held that another step waits on): by ci_step_finish
# below, for the tail's bound.
if [ "$job" = jepsen ]; then
    flock -u 8 2>/dev/null || true
fi
# After the job, still as root: a branch's size is measured again (the job is what grows it; fd 6
# is held, nothing a step waits on is) and the trash a prune or reset filled is emptied a bounded
# time (ci_trash_empty: one removal per mount, no step waits for another's), Jepsen's own too in
# the Jepsen step, and never past the repository's timeout (ci_tail_seconds).
ci_step_finish "$role" "$cache" "${CI_BRANCH_DIR:-}" "$job"
exit "$status"
