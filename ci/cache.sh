#!/usr/bin/env bash
# Sourced by ci/woodpecker_step.sh (and tested by ci/ci_test.sh). The Woodpecker box's caches, and
# the one rule about them (decision O4): only a pipeline for a push to main writes main's caches.
#
#   <root>/main/            main's: tools/ (the pinned Zig's archive, by sha256), zig/, zig-local/
#   <root>/branches/<key>/  one branch's own zig/ and zig-local/; zig/ is seeded by a copy of main's
#
# A branch's pipeline mounts main/ read-only (.woodpecker/*.yaml) and branches/ writable; main's
# mounts main/ writable and not branches/. ci_cache_check refuses a mount that is the wrong way
# round. The mounts are what enforce the rule: this script only notices a wrong one.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# ci_branch_key BRANCH: a directory name for a branch that is safe to use as one and different for
# every branch (the hash tells `a/b` from `a_b`).
ci_branch_key() {
    local safe sum
    safe=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-48)
    sum=$(printf '%s' "$1" | sha256sum | cut -c1-8)
    echo "b-$safe-$sum"
}

# ci_cache_writable DIR: whether this process can create a file in DIR.
ci_cache_writable() {
    local probe="$1/.probe.$$"
    if : > "$probe" 2>/dev/null; then rm -f "$probe"; return 0; fi
    return 1
}

# ci_cache_check ROLE ROOT: ROLE is main or branch. NRV-E1202 if ROOT is not laid out as above, or
# main's directory is writable where it must not be (a branch) or not where it must be (main).
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
    return 0
}

# ci_dir_gib DIR...: the size of the directories together, in GiB rounded up.
ci_dir_gib() {
    du -s -B1G "$@" 2>/dev/null | awk '{n += $1} END {print n + 0}'
}

# ci_branch_prune BRANCHES KEEP MAXN MAXDAYS MAXGIB: removes the branch caches nobody is using
# (no job holds its lock) that are beyond the MAXN most recent, older than MAXDAYS days or larger
# than MAXGIB GiB. KEEP, the caller's own, is never removed. Call with the branches lock held.
ci_branch_prune() {
    local b="$1" keep="$2" maxn="$3" maxdays="$4" maxgib="$5" d name n=0 drop
    rm -rf "$b"/*.partial.* 2>/dev/null || true # a killed seed's; seeds run under the lock
    while IFS= read -r d; do
        d=${d%/}
        name=${d##*/}
        [ "$name" != "$keep" ] || continue
        n=$((n + 1))
        drop=no
        [ "$n" -le "$maxn" ] || drop=yes
        [ -z "$(find "$d" -maxdepth 0 -mtime +"$maxdays" 2>/dev/null)" ] || drop=yes
        [ "$(ci_dir_gib "$d")" -le "$maxgib" ] || drop=yes
        [ "$drop" = yes ] || continue
        (
            exec 5>>"$b/$name.lock"
            # The lock file stays: unlinking it would let a job that opened it first keep a lock
            # on an inode no later prune opens. They are empty, one per branch key.
            flock -x -n 5 && rm -rf "$d"
        ) 2>/dev/null || true
    done < <(ls -1dt "$b"/b-*/ 2>/dev/null)
}

# ci_branch_prepare ROOT BRANCH: creates this branch's cache (zig/ a copy of main's, if that is no
# larger than CI_BRANCH_SEED_MAX_GIB; zig-local/ empty), prunes the others, and holds a shared lock on its own on
# fd 6 for the rest of the process, so a prune by another job leaves it alone. Sets CI_BRANCH_DIR.
# The count, age and size of branch caches are bounded: CI_BRANCH_CACHES (8), CI_BRANCH_CACHE_DAYS
# (7), CI_BRANCH_CACHE_MAX_GIB (12). With CI_BRANCH_PRUNE_ALL=1 (the disk is low) every cache
# nobody is using goes. The lock on fd 7 (branches/.lock) serialises seeding and pruning; fd 6 is
# taken before it is released, so no prune falls between.
ci_branch_prepare() {
    local root="$1" key b dir maxn maxdays maxgib seedgib partial locked=no
    key=$(ci_branch_key "$2")
    b="$root/branches"
    dir="$b/$key"
    maxn="${CI_BRANCH_CACHES:-8}"
    maxdays="${CI_BRANCH_CACHE_DAYS:-7}"
    maxgib="${CI_BRANCH_CACHE_MAX_GIB:-12}"
    seedgib="${CI_BRANCH_SEED_MAX_GIB:-6}"
    [ "${CI_BRANCH_PRUNE_ALL:-}" != 1 ] || maxn=0
    exec 7>>"$b/.lock"
    if flock -x -w "${CI_LOCK_WAIT:-300}" 7; then
        locked=yes
        ci_branch_prune "$b" "$key" "$maxn" "$maxdays" "$maxgib"
        # Its own cache over the size limit starts again, if no job of this branch is using it.
        if [ -d "$dir" ] && [ "$(ci_dir_gib "$dir")" -gt "$maxgib" ]; then
            (
                exec 5>>"$b/$key.lock"
                flock -x -n 5 && echo "branch cache $key is over $maxgib GiB: starting again" >&2 && rm -rf "$dir"
            ) 2>/dev/null || true
        fi
    else
        ci_warning "NRV-W1202: could not take the branch caches' lock in ${CI_LOCK_WAIT:-300} s; $key runs without seeding or pruning"
    fi
    # Our own shared lock first, then the test: a prune by a job that holds fd 7 skips a cache whose
    # lock is held, so it cannot delete $dir between the test and the use (NRV-W1202 path too).
    exec 6>>"$b/$key.lock"
    flock -s 6
    if [ ! -d "$dir" ]; then
        if [ "$locked" = yes ]; then
            partial="$dir.partial.$$"
            mkdir -p "$partial"
            # Only the toolchain's global cache is copied (a plain copy: a hard link would let a
            # branch write main's inode). Main's zig-local may be half written by a build running
            # now, and the branch would keep that for days; it starts empty and fills itself.
            if [ "$(ci_dir_gib "$root/main/zig")" -le "$seedgib" ]; then
                cp -a "$root/main/zig" "$partial/" 2>/dev/null || true
            else
                echo "main's cache is over $seedgib GiB: branch $key starts empty" >&2
            fi
            mkdir -p "$partial/zig" "$partial/zig-local"
            # -T: if a job without the lock made $dir meanwhile, replace nothing and move nothing in.
            mv -T "$partial" "$dir" 2>/dev/null || rm -rf "$partial"
        else
            # No lock on the branches' directory: no shared partial directory a prune could remove.
            mkdir -p "$dir/zig" "$dir/zig-local"
        fi
    fi
    [ "$locked" != yes ] || flock -u 7
    touch "$dir"
    # shellcheck disable=SC2034 # read by ci/woodpecker_step.sh
    CI_BRANCH_DIR="$dir" # not printed: a command substitution would drop the lock with its shell
}

# ci_main_prune ROOT: empties main's Zig caches (never the pinned toolchain) if the lock on fd 9
# (main/.lock) is free within CI_PRUNE_WAIT s: every job holds it shared while it runs, so this is
# called before the caller takes its own shared lock, which it takes after, pruned or not.
ci_main_prune() {
    local root="$1" wait="${CI_PRUNE_WAIT:-600}"
    if flock -x -w "$wait" 9; then
        echo "emptying main's Zig caches (no other job holds them)"
        rm -rf "$root/main/zig" "$root/main/zig-local"
        mkdir -p "$root/main/zig" "$root/main/zig-local"
    else
        ci_warning "NRV-W1202: other jobs held main's cache for $wait s: not pruned. To recover by hand, with the agent idle: rm -rf /var/cache/nerva-ci/main/zig-local /var/cache/nerva-ci/main/zig"
    fi
}
