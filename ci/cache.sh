#!/usr/bin/env bash
# Sourced by ci/woodpecker_step.sh (and tested by ci/ci_test.sh). The Woodpecker box's caches, and
# the one rule about them (decision O4): only a pipeline for a push to main writes main's caches.
#
#   <root>/main/            main's: tools/ (the pinned Zig's archive, by sha256), zig/, zig-local/
#   <root>/branches/<key>/  one branch's own zig/ and zig-local/; zig/p (fetched packages) is seeded
#                         by a copy of main's
#   <root>/locks/           the lock files: main.lock, branches.lock, b-<key>.lock, jepsen.lock.
#                         Owned by the step's user (root), mode 0700, mounted writable in every role.
#                         The directories above belong to `ci`, so a lock file in one could be
#                         replaced by a job (a symlink in its place would make a root step chown
#                         and chmod the target); here a job cannot create, unlink or open anything.
#
# The step runs as root and the job as `ci`, so every path a job can write (all of main/ and
# branches/, and /cache/jepsen) is the job's to redirect: a symlink planted there would make a
# root chown, chmod, install, mkdir or cp, or a root redirection, act on its target. Root therefore
# never creates, chowns, chmods or writes anything there (the exceptions, both on a mount's own
# root, which a job cannot swap for a link: `install -d -o ci /cache/jepsen` in the step, and the
# `chmod 0755` of ci_cache_job_writable, only when the job's own uid owns it). What the job needs made there is made by
# the job user itself (ci_as_job, `mkdir`, `mktemp`, `cp`, `mv`, `touch`), which can only touch what
# the job could touch anyway; root only tests (never acts on the result of a test, so a swap after
# it changes nothing) and unlinks (rm -rf of a path whose parent is a mount root, which never
# follows a link in its last component). A path with any other job-writable component (a
# partial directory's zig/p, a branch's zig link) is unlinked by the job user.
# What is then not a plain directory the job can write is refused: NRV-E1228.
#
# A branch's pipeline mounts main/ read-only (.woodpecker/*.yaml) and branches/ writable; main's
# mounts main/ writable and not branches/. ci_cache_check refuses a mount that is the wrong way
# round (NRV-E1202: root's access(2) test, which only a read-only mount changes, never the owner or
# the mode of the mount root), and a mount root the job's user cannot write (the job's own test: if
# the job owns it and only its mode, from a job's chmod, stops it, it is set back to 0755 with
# NRV-W1203; if another user owns it, NRV-E1229 with the owner and mode in the message). The mounts are
# what enforce the rule: this script only notices a wrong one.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# ci_branch_key BRANCH: a directory name for a branch that is safe to use as one and different for
# every branch (the hash tells `a/b` from `a_b`).
ci_branch_key() {
    local safe sum
    safe=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-48)
    sum=$(printf '%s' "$1" | sha256sum | cut -c1-8)
    echo "b-$safe-$sum"
}

# ci_cache_writable DIR: the mount question: whether DIR is mounted read-write, asked of this user
# (root, in a step) with access(2) (test -w), which answers EROFS for a read-only mount and
# otherwise ignores the mode, so a job that chmods its own mount root cannot change it. Nothing is
# created: a probe file made as root in a directory a job writes would follow a link the job planted
# there, and a directory planted at its name would fail every step.
ci_cache_writable() {
    test -w "$1"
}

# ci_cache_job_writable DIR: the ownership question, apart from the mount's: whether the job's user
# can write DIR (the mount root a job makes its directories in), whoever owns it and whatever its
# mode: Docker makes a missing mount source root 0755, and an owner (a job) can chmod it.
#  - If the job's own uid owns DIR and only the mode stops it (a job's `chmod 0555`), this sets it
#    back to 0755 and warns (NRV-W1203): otherwise one job could fail every later pipeline until an
#    operator acted. Safe, as DIR is a mount's own root, which a job cannot swap for a link or
#    rename (EBUSY) and whose parent, /cache, is root's; a link at DIR is still refused, never
#    followed.
#  - If anyone else owns it, NRV-E1229 names the owner and the mode: root never chowns a host
#    directory it was not given.
ci_cache_job_writable() {
    local d="$1" job_uid was
    ci_as_job test -w "$d" && return 0
    job_uid=$(id -u "${CI_JOB_USER:-$(id -un)}")
    if [ ! -L "$d" ] && [ "$(stat -c %u "$d")" = "$job_uid" ]; then
        was=$(stat -c %a "$d")
        if chmod 0755 -- "$d" 2>/dev/null && ci_as_job test -w "$d"; then
            ci_warning "NRV-W1203: $d, owned by the job's user (${CI_JOB_USER:-$(id -un)}), had mode $was and was not writable: set it back to 0755 (a job's chmod); on the host, run bash ci/nerva-woodpecker.sh host again if this keeps happening"
            return 0
        fi
    fi
    ci_error "NRV-E1229: $d is mounted read-write but the job's user (${CI_JOB_USER:-$(id -un)}) cannot write it (owner $(stat -c '%U, uid %u' "$d"), mode $(stat -c %a "$d")): on the host, run bash ci/nerva-woodpecker.sh host again, or chown it to that user and chmod 0755 it"
    return 1
}

# ci_cache_check ROLE ROOT: ROLE is main or branch. NRV-E1202 if ROOT is not laid out as above, or
# main's directory is writable where it must not be (a branch) or not where it must be (main), or
# branches/ is not writable in a branch's pipeline: the mount's, by root's test, whoever owns the
# directory. Then NRV-E1229 if the directory the job writes (main/ in main's role, branches/ in a
# branch's) is a mount the job's user cannot write.
ci_cache_check() {
    local role="$1" root="$2"
    if [ ! -d "$root/main" ] || { [ "$role" = branch ] && [ ! -d "$root/branches" ]; }; then
        ci_error "NRV-E1202: $root/main (and, for a branch, $root/branches) is not mounted (ops/ci/README.md, 'Nerva on Woodpecker', step 4)"
        return 1
    fi
    if ci_cache_writable "$root/main"; then
        if [ "$role" = branch ]; then
            ci_error "NRV-E1202: main's cache is writable in a pipeline for a branch other than main: mount it :ro (decision O4)"
            return 1
        fi
    elif [ "$role" = main ]; then
        ci_error "NRV-E1202: main's cache is not writable in a pipeline for main: mount /var/cache/nerva-ci/main without :ro"
        return 1
    fi
    if [ "$role" = branch ] && ! ci_cache_writable "$root/branches"; then
        ci_error "NRV-E1202: $root/branches is not writable: mount /var/cache/nerva-ci/branches"
        return 1
    fi
    ci_locks_check "$root" || return 1
    if [ "$role" = main ]; then ci_cache_job_writable "$root/main"; else ci_cache_job_writable "$root/branches"; fi
}

# ci_locks_check ROOT: NRV-E1202 if ROOT/locks is not there (not mounted), NRV-E1226 if it is not a
# real directory (no symlink) owned by this user (root, in a step) that nobody else can write or
# list (no group or other bits at all: a job that can list the directory can open a 0644 lock read
# only, and flock -x works on that). A lock directory a job could write would let it replace a lock
# file and make a root step follow its symlink.
ci_locks_check() {
    local d="$1/locks"
    if [ ! -e "$d" ] && [ ! -L "$d" ]; then
        ci_error "NRV-E1202: $d is not mounted: mount /var/cache/nerva-ci/locks (ops/ci/README.md, 'Nerva on Woodpecker', step 4)"
        return 1
    fi
    if [ -L "$d" ] || [ ! -d "$d" ] || [ "$(stat -c %u "$d")" != "$(id -u)" ] ||
        [ -n "$(find "$d" -maxdepth 0 -perm /077)" ]; then
        ci_error "NRV-E1226: $d is not a plain directory owned by uid $(id -u) that only it can use (mode 0700): on the host, run bash ci/nerva-woodpecker.sh host again (it makes it root:root 0700; Docker makes a missing mount source 0755)"
        return 1
    fi
    return 0
}

# ci_lock_file FILE: makes FILE, a lock file in the lock directory (ci_locks_check), that only this
# user (root, in a step) can open: flock works on a file opened read-only, so another user could
# otherwise take an exclusive lock on a 0644 file and hold every later step up with it. The step
# closes its lock descriptors (6 to 9) for the job (woodpecker_step.sh), so the job holds none
# of them. The directory is not the job's to write, so it cannot replace a lock file either. Even
# so, nothing here follows a link: a symlink at FILE is removed and made again, something that is
# not a regular file is refused (NRV-E1226), and the ownership is set with chown -h. An old lock
# file in a directory of `ci`'s (earlier layout) is simply not used.
ci_lock_file() {
    local f="$1"
    if [ -L "$f" ]; then rm -f "$f" 2>/dev/null || true; fi
    if [ -e "$f" ] && [ ! -f "$f" ]; then
        ci_error "NRV-E1226: lock path $f is not a regular file: remove it on the host"
        return 1
    fi
    # noclobber: created with O_EXCL, so a link planted since the test above is not followed.
    if [ ! -e "$f" ]; then (umask 077 && set -C && : >"$f") 2>/dev/null || true; fi
    if [ -L "$f" ] || [ ! -f "$f" ]; then
        ci_error "NRV-E1226: lock path $f could not be made as a regular file: check the lock directory on the host"
        return 1
    fi
    chown -h "$(id -u):$(id -g)" "$f" 2>/dev/null || true
    chmod 600 "$f" 2>/dev/null || true
}

# ci_lock_open_failed FILE MODE: NRV-E1227, with the reason the open gave (the step's own `exec N>>FILE`
# or `exec N<FILE` just failed; MODE is `>>` or `<`, and the probe opens the same way, so it gives
# the reason the real open had). Not a wait: nothing has been waited for.
ci_lock_open_failed() {
    local why
    case "$2" in
        '<') why=$( { : <"$1"; } 2>&1 || true) ;;
        '>>') why=$( { : >>"$1"; } 2>&1 || true) ;;
        *) ci_error "NRV-B1201: ci_lock_open_failed: mode '$2' is neither < nor >> (a bug in the script that called it)"; return 1 ;;
    esac
    why=${why##*: }
    ci_error "NRV-E1227: could not open the lock file $1 (${why:-no reason given}): check the lock directory on the host"
}

# ci_shared_lock: a shared lock on fd 9 (main's lock), waiting at most CI_MAIN_LOCK_WAIT seconds
# (default 1800; CI_LOCK_WAIT, default 300, is the branch locks'): a holder that never lets go must
# not hold a step up for good. Steps hold it shared, and Linux grants a shared lock beside shared
# ones, so only an exclusive holder blocks: main's prune (ci_main_prune, a long rm -rf) or a
# process on the host. NRV-E1224.
ci_shared_lock() {
    flock -s -w "${CI_MAIN_LOCK_WAIT:-1800}" 9 || {
        ci_error "NRV-E1224: main's cache lock was held for ${CI_MAIN_LOCK_WAIT:-1800} s: main's prune (a long rm -rf of its caches), or a process on the host, holds it exclusively; lslocks on the host shows its pid; if the holder is just slow, raise CI_MAIN_LOCK_WAIT"
        return 1
    }
}

# ci_main_lock_open ROOT: makes main's lock file and opens it on fd 9 (read-only: flock needs no
# write). NRV-E1226 or E1227 if it cannot.
ci_main_lock_open() {
    local f="$1/locks/main.lock"
    ci_lock_file "$f" || return 1
    { exec 9<"$f"; } 2>/dev/null || { ci_lock_open_failed "$f" '<'; return 1; }
}

# ci_as_job CMD...: runs CMD as the job's user, $CI_JOB_USER (default: this user). Root becomes it
# with setpriv; anyone else is already the only user it could be, so CMD runs as is.
ci_as_job() {
    local u="${CI_JOB_USER:-$(id -un)}"
    if [ "$(id -u)" = 0 ] && [ "$u" != root ]; then
        setpriv --reuid "$(id -u "$u")" --regid "$(id -g "$u")" --init-groups "$@"
    else
        "$@"
    fi
}

# ci_job_dir PATH...: makes each PATH (parents first) a plain directory the job user can write, as
# the job user, never as root (see the top). A symlink there is unlinked and replaced (it is the
# job's own doing); anything else that is not a directory the job can write (a file, a directory
# of another user, a link planted again after the unlink) is refused: NRV-E1228.
ci_job_dir() {
    local p
    for p in "$@"; do
        if [ -L "$p" ]; then ci_as_job rm -f -- "$p" 2>/dev/null || true; fi
        if [ ! -e "$p" ] && [ ! -L "$p" ]; then ci_as_job mkdir -- "$p" 2>/dev/null || true; fi
        if [ -L "$p" ] || [ ! -d "$p" ] || ! ci_as_job test -w "$p"; then
            ci_error "NRV-E1228: $p is not a plain directory that the job's user (${CI_JOB_USER:-$(id -un)}) can write (a link, a file, or another user's directory): on the host, rm -rf it (it is only a cache) and start the pipeline again"
            return 1
        fi
    done
}

# ci_dir_gib DIR...: the size of the directories together, in GiB rounded up.
ci_dir_gib() {
    du -s -B1G "$@" 2>/dev/null | awk '{n += $1} END {print n + 0}'
}

# ci_branch_prune BRANCHES LOCKS KEEP MAXN MAXDAYS MAXGIB: removes the branch caches nobody is using
# (no job holds its lock) that are beyond the MAXN most recent, older than MAXDAYS days or larger
# than MAXGIB GiB. KEEP, the caller's own, is never removed and counts
# against MAXN. Call with the branches lock held.
ci_branch_prune() {
    local b="$1" locks="$2" keep="$3" maxn="$4" maxdays="$5" maxgib="$6" rec d name n=0 drop
    # KEEP takes one of the MAXN places (it is made right after, if it is not there yet), so MAXN
    # is the most there are, KEEP included.
    n=1
    rm -rf "$b"/*.partial.* 2>/dev/null || true # a killed seed's; seeds run under the lock
    # Names come NUL-separated from find, never from parsing ls: a job can name a directory with a
    # newline in it, and a line of that name would be taken for a path. A name that is not one
    # ci_branch_key makes, or is not a real directory, is the job's own doing and is removed (a
    # link is unlinked, not followed), with no lock: no job's cache is called that.
    while IFS= read -r -d '' rec; do
        name=${rec#* }
        [ "$name" != "$keep" ] || continue
        if ! [[ "$name" =~ ^b-[A-Za-z0-9._-]+$ ]] || [ -L "$b/$name" ] || [ ! -d "$b/$name" ]; then
            rm -rf -- "${b:?}/$name" 2>/dev/null || true
            continue
        fi
        d="$b/$name"
        n=$((n + 1))
        drop=no
        [ "$n" -le "$maxn" ] || drop=yes
        [ -z "$(find "$d" -maxdepth 0 -mtime +"$maxdays" 2>/dev/null)" ] || drop=yes
        [ "$(ci_dir_gib "$d")" -le "$maxgib" ] || drop=yes
        [ "$drop" = yes ] || continue
        (
            # Made by ci_lock_file: 0600, never followed, in the step's own lock directory.
            ci_lock_file "$locks/$name.lock" || exit 1
            exec 5>>"$locks/$name.lock"
            # The lock file stays: unlinking it would let a job that opened it first keep a lock
            # on an inode no later prune opens. They are empty, one per branch key.
            flock -x -n 5 && rm -rf "$d"
        ) 2>/dev/null || true
    done < <(find "$b" -mindepth 1 -maxdepth 1 -name 'b-*' -printf '%T@ %f\0' 2>/dev/null | sort -z -rn)
}

# ci_branch_prepare ROOT BRANCH: creates this branch's cache (zig/p, the fetched packages, a copy of main's, if that is no
# larger than CI_BRANCH_SEED_MAX_GIB; zig-local/ empty), prunes the others, and holds a shared lock on its own on
# fd 6 for the rest of the process, so a prune by another job leaves it alone. Sets CI_BRANCH_DIR.
# The count, age and size of branch caches are bounded: CI_BRANCH_CACHES (8), CI_BRANCH_CACHE_DAYS
# (7), CI_BRANCH_CACHE_MAX_GIB (12). With CI_BRANCH_PRUNE_ALL=1 (the disk is low) every cache
# nobody is using goes. The lock on fd 7 (locks/branches.lock) serialises seeding and pruning; fd 6 is
# taken before it is released, so no prune falls between.
ci_branch_prepare() {
    local root="$1" key b dir locks maxn maxdays maxgib seedgib partial err last locked=no
    key=$(ci_branch_key "$2")
    b="$root/branches"
    dir="$b/$key"
    locks="$root/locks"
    maxn="${CI_BRANCH_CACHES:-8}"
    maxdays="${CI_BRANCH_CACHE_DAYS:-7}"
    maxgib="${CI_BRANCH_CACHE_MAX_GIB:-12}"
    seedgib="${CI_BRANCH_SEED_MAX_GIB:-6}"
    [ "${CI_BRANCH_PRUNE_ALL:-}" != 1 ] || maxn=0
    ci_lock_file "$locks/branches.lock" || return 1
    { exec 7>>"$locks/branches.lock"; } 2>/dev/null || { ci_lock_open_failed "$locks/branches.lock" '>>'; return 1; }
    if flock -x -w "${CI_LOCK_WAIT:-300}" 7; then
        locked=yes
        ci_branch_prune "$b" "$locks" "$key" "$maxn" "$maxdays" "$maxgib"
        # Its own cache over the size limit starts again, if no job of this branch is using it.
        if [ -d "$dir" ] && [ "$(ci_dir_gib "$dir")" -gt "$maxgib" ]; then
            (
                ci_lock_file "$locks/$key.lock" || exit 1
                exec 5>>"$locks/$key.lock"
                flock -x -n 5 && echo "branch cache $key is over $maxgib GiB: starting again" >&2 && rm -rf "$dir"
            ) 2>/dev/null || true
        fi
    else
        ci_warning "NRV-W1202: could not take the branch caches' lock in ${CI_LOCK_WAIT:-300} s; $key runs without seeding or pruning"
    fi
    # Our own shared lock first, then the test: a prune by a job that holds fd 7 skips a cache whose
    # lock is held, so it cannot delete $dir between the test and the use (NRV-W1202 path too).
    # (One empty b-<key>.lock stays per branch name the box has seen; a prune never unlinks them.)
    ci_lock_file "$locks/$key.lock" || { [ "$locked" != yes ] || flock -u 7; return 1; }
    if ! { exec 6>>"$locks/$key.lock"; } 2>/dev/null; then
        ci_lock_open_failed "$locks/$key.lock" '>>'
        [ "$locked" != yes ] || flock -u 7
        return 1
    fi
    flock -s -w "${CI_LOCK_WAIT:-300}" 6 || {
        ci_error "NRV-E1225: $key's own cache lock was held for ${CI_LOCK_WAIT:-300} s: another step's prune of this branch's cache (it holds the lock exclusively while it removes it; see NRV-W1202), or a process on the host, holds it; lslocks on the host shows its pid; if the holder is just slow, raise CI_LOCK_WAIT"
        [ "$locked" != yes ] || flock -u 7
        return 1
    }
    # A link at $dir is the job's own doing: unlinked (never followed), then made again below.
    if [ -L "$dir" ]; then rm -f -- "$dir" 2>/dev/null || true; fi
    if [ ! -e "$dir" ]; then
        # Everything under $b is made by the job's user (ci_as_job), never by root: nothing root
        # does can then follow a link there. The partial directory has a name of mktemp's, made
        # with O_EXCL, so a link planted at a guessed name is not used.
        if [ "$locked" = yes ] && partial=$(ci_as_job mktemp -d "$b/$key.partial.XXXXXX" 2>/dev/null); then
            # Only zig/p, the fetched packages, is copied: they are content-addressed and written
            # once. Main's other global-cache files and its zig-local are rewritten by main's jobs,
            # which hold main's lock shared, as this job does (the shared flock in the step script):
            # nothing keeps them out while this copies, so a copy could keep a torn file for days.
            # They start empty and fill themselves. A plain copy: a hard link would let a branch
            # write main's inode.
            ci_as_job mkdir "$partial/zig"
            if [ ! -d "$root/main/zig/p" ]; then
                echo "main has no package cache yet: branch $key starts empty" >&2
            elif [ "$(ci_dir_gib "$root/main/zig/p")" -le "$seedgib" ]; then
                # A failed copy must not leave a partial zig/p (a half-written package would be trusted).
                # cp's reason is kept in memory: on a full disk a file in $partial could not hold it.
                if ! err=$(ci_as_job cp -a "$root/main/zig/p" "$partial/zig/" 2>&1 >/dev/null); then
                    last=${err##*$'\n'}
                    echo "seed copy failed: branch $key starts empty (${last:-no message})" >&2
                    ci_as_job rm -rf "$partial/zig/p" # as the job: $partial/zig is its to swap for a link
                fi
            else
                echo "main's package cache is over $seedgib GiB: branch $key starts empty" >&2
            fi
            ci_as_job mkdir -p "$partial/zig" "$partial/zig-local"
            # -T: if a job without the lock filled $dir meanwhile, keep its directory and drop the seed.
            ci_as_job mv -T "$partial" "$dir" 2>/dev/null || rm -rf "$partial"
        else
            # No lock on the branches' directory (or no partial directory could be made): no
            # shared partial directory a prune could remove.
            ci_as_job mkdir -p "$dir/zig" "$dir/zig-local" 2>/dev/null || true
        fi
    fi
    # The branches' lock is let go before anything can return: seeding is done, or never started.
    [ "$locked" != yes ] || flock -u 7
    # Whichever way $dir was made (or not), it must be a directory now (a file there is the box's damage).
    [ -d "$dir" ] || { ci_error "NRV-E1214: $dir is not a directory: remove it"; return 1; }
    # The job's own directories, as the job user: a missing one is made, a link is replaced, and
    # one the job cannot write (a file, another user's) is refused (NRV-E1228). No chown: root
    # touches nothing in $dir.
    ci_job_dir "$dir" "$dir/zig" "$dir/zig-local" || return 1
    ci_as_job touch "$dir"
    # shellcheck disable=SC2034 # read by ci/woodpecker_step.sh
    CI_BRANCH_DIR="$dir" # not printed: a command substitution would drop the lock with its shell
}

# ci_main_prune ROOT MIN_GIB: empties main's Zig caches (never the pinned toolchain) when the box
# is low on space (under MIN_GIB free) and the lock on fd 9 (locks/main.lock) is free: every job holds it
# shared while it runs, so this is called before the caller takes its own shared lock, which it
# takes after, pruned or not. One pruner per push is enough, so the wait is short (CI_PRUNE_WAIT,
# default 5 s) and, once it ends (lock taken or not), space is measured again: if another job has
# freed it, nothing is pruned and nothing is warned. NRV-W1202 only if space is still low and the
# lock was not free.
ci_main_prune() {
    local root="$1" min="$2" wait="${CI_PRUNE_WAIT:-5}" got=no
    flock -x -w "$wait" 9 && got=yes
    if [ "$(df --output=avail -B1G "$root/main" | tail -1 | tr -d ' ')" -ge "$min" ]; then
        echo "main's cache: space is free again, not pruning"
    elif [ "$got" = yes ]; then
        echo "emptying main's Zig caches (no other job holds them)"
        rm -rf "$root/main/zig" "$root/main/zig-local" # a link there is unlinked, not followed
    else
        ci_warning "NRV-W1202: other jobs held main's cache for $wait s: not pruned. To recover by hand, with the agent idle: rm -rf /var/cache/nerva-ci/main/zig-local /var/cache/nerva-ci/main/zig"
    fi
}

# ci_main_prepare ROOT USER LOW MIN_GIB: the main role's cache set-up, run as root, in this order:
# the lock file (ours, 0600) and its fd 9, the prune (when LOW is yes), and only then main's
# directories, made by USER itself (ci_job_dir): root chowns and installs nothing in main/, which a
# job writes, so a link a job planted at main/zig, zig-local or tools is replaced or refused
# (NRV-E1228), never followed. The prune removes main/zig and main/zig-local, so the directories
# come after it. The caller takes its shared lock (flock -s 9) after this returns.
ci_main_prepare() {
    local root="$1" CI_JOB_USER="$2" low="$3" min="$4"
    ci_main_lock_open "$root" || return 1 # root's, in the lock directory a job cannot write
    [ "$low" = no ] || { echo "Below $min GiB free"; ci_main_prune "$root" "$min"; }
    ci_job_dir "$root/main/zig" "$root/main/zig-local" "$root/main/tools"
}
