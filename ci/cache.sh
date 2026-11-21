#!/usr/bin/env bash
# Sourced by ci/woodpecker_step.sh (and tested by ci/ci_test.sh). The Woodpecker box's caches, and
# the one rule about them (decision O4): only a pipeline for a push to main writes main's caches.
#
#   <root>/main/            main's: tools/ (the pinned Zig's archive, by sha256), zig/, zig-local/
#   <root>/branches/<key>/  one branch's own zig/ and zig-local/; zig/p (fetched packages) is seeded
#                         by a copy of main's
#   <root>/locks/           the lock files: main.lock, branches.lock, b-<key>.lock, jepsen.lock, and
#                         <root>-children.lock (main-, branches-, jepsen-) for making a child.
#                         Owned by the step's user (root), mode 0700, mounted writable in every role.
#                         The directories above belong to `ci`, so a lock file in one could be
#                         replaced by a job (a symlink in its place would make a root step chown
#                         and chmod the target); here a job cannot create, unlink or open anything.
#
# The step runs as root and the job as `ci`, so everything a job can write is the job's to
# redirect: a symlink planted there would make a root chown, chmod, install, mkdir or cp, or a root
# redirection, act on its target. Review rounds 1 to 17 closed that one case at a time (a chmod 0555
# of a cache directory, then 0600, 0666 and 0200, a default ACL, a file or a FIFO at a child, deeper
# paths): each fix left the next way to leave a directory the job could not use. The eighteenth
# round ends the class (decision O4, worklog/O4.md) with three rules:
#
#  1. A MOUNT ROOT IS NEVER THE JOB'S (/cache/main in main's role, /cache/branches in a branch's,
#     /cache/jepsen): root-owned, a real directory, mode 0755, no ACL (ci_mount_root, on every step;
#     `host` makes them so). A job cannot chmod, chown, ACL, rename or unlink anything at that
#     level, and cannot create a name in it. Root makes the direct children the job needs (a
#     branch's b-<key>, main's zig, zig-local and tools, jepsen's tools and each run's directory)
#     with mkdir and chown (ci_child_make): safe, as the parent is root's and a job cannot swap it.
#  2. A DIRECT CHILD THE JOB OWNS BUT CANNOT USE IS RESET BY ROOT, WHATEVER ITS TYPE (a directory
#     that is not usable, a file, a FIFO, a socket; a link is unlinked): root renames that one name
#     directly in a root-owned directory into the mount root's trash (mv -T into <mount>/.trash,
#     ci_trash_move: a rename, which never follows a link), makes a fresh child with mkdir and chown,
#     NRV-W1204 (ci_child_reset, under the lock that keeps the other jobs out: the key's lock for a
#     branch, main's exclusive one for main, the Jepsen lock for jepsen), and removes the trash after
#     the locks are let go (ci_trash_empty). A child another uid owns is never touched: NRV-E1228.
#
#     THE DESIGN RULE for every lock other steps wait on (branches.lock, main.lock, a key lock held
#     exclusively, the children lock): under it root only DECIDES and RENAMES. It never walks a tree a
#     job made (rm -rf, du, find): a job's tree can hold millions of files, and a walk of it under a
#     lock holds every other step past its wait (NRV-W1202, NRV-E1228, NRV-E1224). A tree to drop is
#     renamed into MOUNT/.trash, which is root's alone (mode 0700, not a link, no ACL, the mount
#     root's own file system, so mv can never fall back to a copy: NRV-E1236 otherwise, nothing moved),
#     and removed by ci_trash_empty after `flock -u`, bounded by CI_NORMALIZE_SECONDS, which tolerates a
#     job still writing in a moved tree (NRV-W1205 if it cannot empty it; the next call retries). A
#     branch's size is measured by its own step after the locks (ci_branch_measure, a record in
#     locks/<key>.size; a du that outlasts CI_BRANCH_DU_SECONDS counts as over every bound), so the
#     prune reads records and walks nothing. Accepted: the seed's cp -a of main/zig/p runs under the
#     branches' lock and main's shared one, and a failed cp's cleanup is the job's own rm.
#  3. THE JOB'S OWN TREE IS NORMALIZED BY THE JOB (ci_normalize, before each use): as the job,
#     every directory under the child gets u+rwx and loses its ACLs (access and default), a file
#     without u+rw gets it, a FIFO or a socket is removed, and each top-level name Zig needs
#     (ci_known_dirs: b h o p tmp z under zig and zig-local) that is a link or not a directory is
#     removed. The job acting on its own files cannot escalate, so this walks deep paths
#     (main/zig/o/x, a branch's zig/p, jepsen/tools) that root never walks. It is judged by what
#     it leaves, not by find's exit status (GNU find exits 1 on an entry another job removed
#     during the walk, even with -ignore_readdir_race: about 2 walks in 100 under churn). If the
#     child still has an ACL, is not usable or a known name is still wrong, rule 2 applies.
#
# What the three rules guarantee: no job can make a root operation act through a path it
# controls (the paths named above, "by path": a job that already had a directory open or as its
# working directory before it was moved aside can still write in it until the trash is emptied), and a job's damage to the directories and the top-level names above is repaired
# before the next job runs. What they do not (the accepted limit, decision O4, nineteenth
# review): content damage below those names is the job's own, such as a corrupt cache file or a
# file a job leaves where a Zig cache subdirectory (zig-local/o/<hash>) is expected. It makes the
# builds that read it fail, never a root operation, and clears when the cache is removed. The
# 7-day prune removes only an IDLE branch cache (every step of a branch touches its directory, so
# a branch that keeps running keeps it); main's and jepsen's caches are never pruned by age
# (main's only when the disk is low). At once, on the host, `nerva-woodpecker.sh reset-cache`
# removes main's (`main`), a branch's (`BRANCH`, or `--branch NAME`, which reaches a manual
# pipeline on main: it runs in the branch role, key b-main-<sum>) or jepsen's tools (`jepsen`),
# under the same locks. Concurrent steps do not refuse each other over a reset: the reset is a
# rename under <root>-children.lock (root-only, in locks/), so the step that loses the race finds the
# other's fresh directory, and a step that finds a root-owned directory waits on it for the owner
# change (NRV-E1234 on timeout). What still gives NRV-E1228 is a child another uid owns, one that
# is still not usable after the reset, and a branch's directory whose key lock other steps of that
# branch hold at the same moment (steps that all find it unusable at once need it exclusively, and none
# gets it: the next step, which finds the fresh directory, runs). A main step holds main's
# lock shared from before its first probe (ci_main_prepare), so a reset never falls in the middle.
#
# What root does inside a mount root, in all: mkdir, chown (-h), mktemp -d, mv -T of a partial
# directory, mv -T of a DIRECT child into the mount root's .trash, rm -rf --one-file-system of the
# trash's names (never under a lock others wait on), rm -f of a name that is a DIRECT child, and, on a mount
# root itself (a mount's own root, which a job cannot swap for a link or rename: EBUSY), chown,
# chmod 0755 and setfacl -b -k. It never acts on a deeper path, and everything below a child is made,
# changed and removed by the job's user (ci_as_job: `mkdir`, `cp`, `touch`, `rm`, `find`, `chmod`).
# What is then not a directory the job can use, and cannot be reset, is refused: NRV-E1228.
#
# A branch's pipeline mounts main/ read-only (.woodpecker/*.yaml) and branches/ writable; main's
# mounts main/ writable and not branches/. ci_cache_check refuses a mount that is the wrong way
# round (NRV-E1202: root's access(2) test, which only a read-only mount changes, never the owner or
# the mode of the mount root), and ci_mount_root a mount root that is not root-owned 0755 with no ACL
# (repaired with NRV-W1203 when root or the job's uid owns it, as an earlier layout and a job's own
# chmod leave it; NRV-E1229 when another uid does, or it is a link, or its ACL cannot be removed).
# In a branch's pipeline main/ is read-only: a main job's damage in it is repaired by the next
# pipeline for main, the only one that can write it.
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

# ci_job_uid: the job's user's uid ($CI_JOB_USER, default: this user).
ci_job_uid() {
    id -u "${CI_JOB_USER:-$(id -un)}"
}

# ci_job_not_root WHO: NRV-B1202 when this process is root and the job's user is root too (no
# $CI_JOB_USER, or root): what ci_normalize and ci_job_dir do "as the job" would then be done as
# root, through paths the job controls (a link it planted, a chmod or an rm -rf that follows it).
# Every caller that runs as root sets CI_JOB_USER (ci/woodpecker_step.sh does).
ci_job_not_root() {
    if [ "$(id -u)" = 0 ] && [ "$(ci_job_uid)" = 0 ]; then
        ci_error "NRV-B1202: $1 would run as root: it acts on a job's own tree and must run as the job's user, but this step is root and CI_JOB_USER is ${CI_JOB_USER:-unset} (a bug in the script that called it: set CI_JOB_USER)"
        return 1
    fi
}

# ci_knobs_check: NRV-E1208 when CI_NORMALIZE_SECONDS, CI_CHILD_LOCK_WAIT, CI_BRANCH_DU_SECONDS or
# CI_MIN_FREE_INODES, if set, is not a whole number (1 or more, at most six digits). The seconds go
# to timeout(1) and flock -w, where 0 means no limit or no wait, and anything else is an error from
# a root step's tool; the inode threshold is compared as a number.
ci_knobs_check() {
    local n
    for n in CI_NORMALIZE_SECONDS CI_CHILD_LOCK_WAIT CI_BRANCH_DU_SECONDS CI_MIN_FREE_INODES; do
        [ -z "${!n:-}" ] || [[ "${!n}" =~ ^[1-9][0-9]{0,5}$ ]] || {
            ci_error "NRV-E1208: $n='${!n}' is not a whole number (1 or more, at most six digits; seconds, or inodes for CI_MIN_FREE_INODES)"
            return 1
        }
    done
}

# ci_job_usable DIR: whether the job's user can use DIR as a directory it makes things in: writable
# AND searchable, asked as the job (access(2) for it). `test -w` alone ignores the search bit: a
# job's `chmod 0600`, `0666` or `0200` of its own directory leaves it writable by the mode and yet
# nothing can be made inside it (review 6001444818). The one question every check of a job's
# directory (ci_child_probe, ci_job_dir) asks.
ci_job_usable() {
    ci_as_job sh -c 'test -w "$1" && test -x "$1"' _ "$1"
}

# ci_has_acl PATH: whether PATH carries an ACL beyond its mode, a default one included (a directory
# with `setfacl -d` makes everything created in it come out with that ACL, mode 0 if it says so).
# `ls -l` marks both with a `+` after the mode, so nothing needs the acl package to ask. Only a test.
ci_has_acl() {
    local m
    m=$(ls -ldn -- "$1" 2>/dev/null) || return 1
    [[ "${m%% *}" == *+ ]]
}

# ci_acl_strip PATH: removes every ACL entry of PATH, the default ACL too (setfacl -b -k). NRV-E1233
# if setfacl is not there (the acl package: ci/woodpecker_step.sh installs it).
ci_acl_strip() {
    command -v setfacl >/dev/null || {
        ci_error "NRV-E1233: setfacl is not installed, so an ACL cannot be removed from $1 (the acl package: apt-get install acl; on the host, the same before running nerva-woodpecker.sh host)"
        return 1
    }
    setfacl -b -k -- "$1" 2>/dev/null
}

# ci_mount_root DIR: rule 1 (see the top): DIR, a mount root a job writes in (main/ in main's role,
# branches/ in a branch's, jepsen/), must be a real directory owned by this user (root, in a step),
# mode 0755, no ACL.
#  - Docker makes a missing mount source root 0755, and `host` makes it so: nothing to do.
#  - Owned by the job's uid (an earlier layout, where the jobs' own directory was the mount root, or
#    a job's own chmod or ACL while it still owned it), or by this user with another mode or an ACL:
#    repaired, chown first (a job cannot then change it again), then chmod 0755 and the ACL's removal,
#    NRV-W1203. Safe: DIR is a mount's own root, which a job cannot swap for a link or rename
#    (EBUSY) and whose parent, /cache, is root's; a link at DIR is never followed.
#  - Anyone else's, a link, not a directory, or an ACL that cannot be removed: NRV-E1229 with what
#    it is; root never chowns a host directory that is no job's.
ci_mount_root() {
    local d="$1" me job_uid owner mode acl=no was
    me=$(id -u)
    job_uid=$(ci_job_uid)
    if [ -L "$d" ]; then
        # The link's own mode is always 777 and says nothing; it is never followed.
        ci_error "NRV-E1229: $d is mounted read-write but is a link, not a directory (it is never followed), and a job's mount root must be root-owned, mode 0755: on the host, remove the link and run bash ci/nerva-woodpecker.sh host again"
        return 1
    fi
    if [ ! -d "$d" ]; then
        ci_error "NRV-E1229: $d is not a directory: on the host, remove it and run bash ci/nerva-woodpecker.sh host again"
        return 1
    fi
    owner=$(stat -c %u "$d")
    mode=$(stat -c %a "$d")
    ! ci_has_acl "$d" || acl=yes
    if [ "$owner" = "$me" ] && [ "$mode" = 755 ] && [ "$acl" = no ]; then return 0; fi
    if [ "$owner" != "$me" ] && [ "$owner" != "$job_uid" ]; then
        ci_error "NRV-E1229: $d is mounted read-write but is owned by neither this step's user nor the job's (${CI_JOB_USER:-$(id -un)}): owner $(stat -c '%U, uid %u' "$d"), mode $mode; on the host, run bash ci/nerva-woodpecker.sh host again, or chown it to root and chmod 0755 it"
        return 1
    fi
    was="owner $(stat -c %U "$d"), mode $mode"
    [ "$acl" = no ] || was="$was, with an ACL"
    if chown -h "$me:$(id -g)" -- "$d" 2>/dev/null && chmod 0755 -- "$d" 2>/dev/null &&
        { [ "$acl" = no ] || ci_acl_strip "$d"; } &&
        [ "$(stat -c '%u %a' "$d")" = "$me 755" ] && ! ci_has_acl "$d"; then
        ci_warning "NRV-W1203: $d, a mount root, was not root-owned 0755 with no ACL ($was): set to it (the job's own doing, or an earlier layout; a job cannot change it now); on the host, run bash ci/nerva-woodpecker.sh host again"
        return 0
    fi
    ci_error "NRV-E1229: $d is mounted read-write but could not be made root-owned, mode 0755, with no ACL ($was; removing an ACL needs the acl package's setfacl): on the host, run bash ci/nerva-woodpecker.sh host again"
    return 1
}

# ci_known_dirs PATH: the names, relative to PATH, that Zig's cache layout fixes as directories, one
# per line, parents first: in a Zig cache directory (main's zig and zig-local) `b`, `h`, `o`, `p`,
# `tmp` and `z` (a real global cache on this box has exactly these; Zig makes them itself, with
# makePath, so a file at one of them fails every later build); in a branch's directory, the same under its
# `zig` and `zig-local` (those two themselves are ci_job_dir's, as the job, with NRV-W1204). Nothing for the other children (tools, jepsen's).
ci_known_dirs() {
    local z n
    case "$(basename -- "$1")" in
        zig | zig-local) for n in b h o p tmp z; do echo "$n"; done ;;
        b-*) for z in zig zig-local; do
            for n in b h o p tmp z; do echo "$z/$n"; done
        done ;;
    esac
}

# ci_normalize DIR: rule 3. As the job's user, over DIR, a directory of its own (never a link; the
# caller tests that), in four steps:
#  1. the modes: every directory gets u+rwx (find acts on a directory before it enters it, so a
#     chmod 0000 one is opened up and then searched: that chmod is `-exec ... \;`, one per
#     directory, as `-exec ... +` would run it only after find had failed to enter the directory),
#     a file without u+rw gets it (a read-only manifest breaks Zig's next write), a FIFO or socket
#     is removed; files and FIFOs go to chmod and rm in batches (`+`: 20 000 files at mode 0400
#     took 26.7 s with a fork each). find runs with
#     -ignore_readdir_race, and its exit status is never the verdict: other jobs of the same key
#     churn the tree while this walks it (Zig makes tmp/<x> and renames it into o/ all the time),
#     and GNU find exits 1 when an entry vanishes mid-walk (the option covers an entry that goes
#     between the readdir and the stat, not a directory that goes before find opens it: measured,
#     about 1 walk in 50 under a Zig-like churn either way). A "No such file or directory" from
#     find, chmod or rm is dropped, any other message is passed on (stderr), and only the checks
#     below judge the tree.
#  2. the names of ci_known_dirs: whatever is there that is not a directory (a file, a link, a
#     FIFO) is removed, so that Zig makes the directory.
#  3. every directory loses its ACL entries, default ones included (setfacl -b -k, many directories
#     per call; "not supported" on a file system without ACLs is no failure).
#  4. the verdict: every known name is a directory (no link) or not there.
# What it does NOT promise: the content and the type of anything deeper (a file where Zig expects
# a directory below o/ or z/, a corrupt manifest): that is the job's own damage. It clears when
# the cache is removed: by the branch's prune once the branch has been idle for 7 days (every
# step of a branch touches its directory, so a branch that keeps running is never pruned), or at
# once by `nerva-woodpecker.sh reset-cache` (main, a branch, a manual pipeline on main with
# `--branch main`, or jepsen). Bounded by CI_NORMALIZE_SECONDS (default 600, a whole number of
# seconds, NRV-E1208 otherwise): a tree it cannot get through in that time counts as failed, and
# is reset by the caller. NRV-E1233 without setfacl. Never run as root with the job's user unset
# or root (NRV-B1202).
ci_normalize() {
    local d="$1" known=()
    ci_job_not_root ci_normalize || return 1
    ci_knobs_check || return 1
    command -v setfacl >/dev/null || {
        ci_error "NRV-E1233: setfacl is not installed, so the ACLs of $d cannot be removed (the acl package: ci/woodpecker_step.sh installs it)"
        return 1
    }
    mapfile -t known < <(ci_known_dirs "$d")
    ci_as_job timeout "${CI_NORMALIZE_SECONDS:-600}" sh -c '
        d=$1
        shift
        err=$(find "$d" -ignore_readdir_race -xdev \( -type d ! -perm -u=rwx -exec chmod u+rwx -- {} \; \) -o \
            \( -type f ! -perm -u=rw -exec chmod u+rw -- {} + \) -o \
            \( \( -type p -o -type s \) -exec rm -f -- {} + \) 2>&1 >/dev/null) || true
        printf "%s\n" "$err" | grep -v -e "No such file or directory" -e "^$" >&2 || true
        for p in "$@"; do
            q=$d/$p
            if [ -L "$q" ] || { [ -e "$q" ] && [ ! -d "$q" ]; }; then rm -rf --one-file-system -- "$q" || true; fi
        done
        find "$d" -ignore_readdir_race -xdev -type d -exec setfacl -b -k -- {} + 2>/dev/null || true
        for p in "$@"; do
            q=$d/$p
            if [ -L "$q" ] || { [ -e "$q" ] && [ ! -d "$q" ]; }; then exit 1; fi
        done
        exit 0
    ' _ "$d" "${known[@]}"
}

# ci_trash_ready MOUNT: whether MOUNT/.trash is a place root can move a tree into: made here (mode
# 0700) if it is not there, then a real directory (never a link) of this user's, mode 0700 with no
# ACL (so no job can open or write it by path), on the same file system as MOUNT (so that a move in
# is a rename). NRV-E1236 and return 1 if not.
ci_trash_ready() {
    local mount="$1" t="$1/.trash"
    if [ ! -e "$t" ] && [ ! -L "$t" ]; then mkdir -m 0700 -- "$t" 2>/dev/null || true; fi
    if [ -L "$t" ] || [ ! -d "$t" ] || [ "$(stat -c %u -- "$t")" != "$(id -u)" ] || [ -n "$(find "$t" -maxdepth 0 -perm /077)" ] ||
        ci_has_acl "$t" || [ "$(stat -c %d -- "$t")" != "$(stat -c %d -- "$mount")" ]; then
        ci_error "NRV-E1236: $t is not a plain directory of uid $(id -u)'s, mode 0700, with no ACL, on the same file system as $mount, so a cache directory could not be moved aside (root never walks a tree a job made while it holds a lock others wait on): on the host, rm -rf it and run bash ci/nerva-woodpecker.sh host again"
        return 1
    fi
}

# ci_trash_move PATH: the one thing root does to a tree a job made while it holds a lock other steps
# wait on (the design rule at the top): it RENAMES it. PATH, a DIRECT child of a mount root (root's),
# is moved with mv -T into a box of mktemp's making in MOUNT/.trash (ci_trash_ready: root's, 0700,
# so no job can open it by path; in the mount root itself, so that the move is a rename within one
# mount: /cache/locks and /cache/main are separate bind mounts in a step's container, and a move
# between them would be EXDEV, which mv answers by COPYING the tree). mv can never copy here: PATH
# must be on the same file system as the trash too, and `--no-copy` is given where mv has it. The
# caller lets its lock go and then calls ci_trash_empty. A link is moved as the link, never
# followed. A concurrent step's ci_trash_empty may remove the empty box between the mktemp and the
# mv: tried three times. NRV-E1236 if the trash is not right; return 1 without a message if the
# move itself failed (the name stays, and the caller refuses it).
ci_trash_move() {
    local p="$1" mount t box n nocopy=()
    mount=$(dirname -- "$p")
    t="$mount/.trash"
    ci_trash_ready "$mount" || return 1
    [ "$(stat -c %d -- "$p" 2>/dev/null)" = "$(stat -c %d -- "$t")" ] || return 1
    if mv --help 2>&1 | grep -q -e '--no-copy'; then nocopy=(--no-copy); fi
    for n in 1 2 3; do
        box=$(mktemp -d "$t/t.XXXXXX" 2>/dev/null) || {
            ci_error "NRV-E1236: could not make a directory in $t (a full disk?): $p was left where it is"
            return 1
        }
        mv -T "${nocopy[@]}" -- "$p" "$box/x" 2>/dev/null && return 0
        [ -e "$p" ] || [ -L "$p" ] || return 1
    done
    return 1
}

# ci_trash_empty MOUNT: removes whatever is in MOUNT/.trash (ci_trash_move's; a crashed step's
# included): rm -rf --one-file-system of each direct child, never following a link (GNU rm walks
# fd-relative; the trash is root's 0700, so no job can swap a name in it). Called with no lock held
# that another step waits on, and bounded: each try ends after CI_NORMALIZE_SECONDS (default 600).
# A job that still has a working directory in a moved tree can keep creating files in it while
# this runs (the rename cuts off its `..`, not its cwd), so it is tried twice; if the trash is
# still not empty, NRV-W1205 and the next step empties it (nothing waits for it).
ci_trash_empty() {
    local t="$1/.trash" n
    [ -d "$t" ] && [ ! -L "$t" ] && [ "$(stat -c %u -- "$t")" = "$(id -u)" ] || return 0
    for n in 1 2; do
        timeout "${CI_NORMALIZE_SECONDS:-600}" find "$t" -mindepth 1 -maxdepth 1 -exec rm -rf --one-file-system -- {} + 2>/dev/null || true
        [ -z "$(find "$t" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ] && return 0
    done
    ci_warning "NRV-W1205: $t could not be emptied (a job still writing in a tree moved there, a mount inside it, or too big to remove in ${CI_NORMALIZE_SECONDS:-600} s): nothing waits for it, and the next step removes what is left"
}

# ci_children_locked PATH CMD...: runs CMD (a command or one of these functions) holding the
# exclusive "children" lock of the mount root PATH is a direct child of (locks/<root>-children.lock:
# main-children.lock, branches-children.lock, jepsen-children.lock), waiting at most
# CI_CHILD_LOCK_WAIT seconds (default 30; the holders only mkdir and chown). Every root-made child
# is made under it (ci_child_make): a directory is root-owned between its mkdir and its chown, and
# a step that looked at it then took it for somebody else's (171 of 420 steps in the review's stress
# run). A step that finds a root-owned child waits for this lock too (ci_child_probe). NRV-E1234.
ci_children_locked() {
    local p="$1" f
    shift
    ci_knobs_check || return 1
    f="$(dirname -- "$(dirname -- "$p")")/locks/$(basename -- "$(dirname -- "$p")")-children.lock"
    (
        ci_lock_file "$f" || exit 1
        { exec 4>>"$f"; } 2>/dev/null || { ci_lock_open_failed "$f" '>>'; exit 1; }
        flock -x -w "${CI_CHILD_LOCK_WAIT:-30}" 4 || {
            ci_error "NRV-E1234: the lock $f, which covers making a cache directory, was held for ${CI_CHILD_LOCK_WAIT:-30} s: it is held only for a mkdir and a chown, so a process on the host (lslocks shows its pid) holds it; if the box is just overloaded, raise CI_CHILD_LOCK_WAIT"
            exit 1
        }
        "$@"
    )
}

# ci_child_probe PATH: the state of PATH, a DIRECT child of a mount root that the job's user is
# to own (a branch's directory, main's zig, zig-local or tools, jepsen's tools), as the return code:
#   0   a directory the job owns and can use, after ci_normalize and with no ACL: nothing to do
#   10  nothing there (a link was: it is the job's doing, unlinked, never followed, no lock needed)
#   11  the job owns it and it cannot be used: not a directory (a file, a FIFO, a socket), a
#       directory that is not usable or has an ACL or could not be normalized: ci_child_reset
#   12  another uid owns it (root never touches it), or a link that could not be unlinked
# On a directory this user owns (root's, perhaps just made by a concurrent step's ci_child_make:
# its mkdir and its chown are two calls) it waits for the children lock, which that step holds until
# the chown is done, and looks again; never on a real owner's.
ci_child_probe() {
    local p="$1" job_uid owner
    job_uid=$(ci_job_uid)
    if [ -L "$p" ]; then rm -f -- "$p" 2>/dev/null || true; fi
    if [ -L "$p" ]; then return 12; fi
    [ -e "$p" ] || return 10
    owner=$(stat -c %u -- "$p" 2>/dev/null) || return 10
    if [ "$owner" = "$(id -u)" ] && [ "$owner" != "$job_uid" ] && [ -d "$p" ]; then
        # Root's: a concurrent step's ci_child_make is between its mkdir and its chown, and holds
        # the children lock until the chown is done. Taking it waits for that, then looks again.
        ci_children_locked "$p" true || return 12
        owner=$(stat -c %u -- "$p" 2>/dev/null) || return 10
    fi
    [ "$owner" = "$job_uid" ] || return 12
    [ -d "$p" ] || return 11
    ci_normalize "$p" || return 11
    ! ci_has_acl "$p" || return 11
    ci_job_usable "$p" || return 11
    return 0
}

# ci_child_make PATH: makes PATH, a DIRECT child of a root-owned mount root, a directory the job's
# user owns: mkdir, then chown -h of the name (rule 1: nobody but root can have made or swapped it).
# A directory a concurrent step made first is fine. Return 1 if there is no such directory after.
ci_child_make() {
    ci_children_locked "$1" ci_child_make_locked "$1"
}

# ci_child_make_locked PATH: ci_child_make's body, run with the children lock held (a concurrent
# step's mkdir and chown of the same name cannot then be seen half done). A directory that is there
# already must be the job's: one another uid owns is refused.
ci_child_make_locked() {
    local p="$1" job_uid
    job_uid=$(ci_job_uid)
    if mkdir -m 0755 -- "$p" 2>/dev/null; then
        chown -h "$job_uid:$(id -g "${CI_JOB_USER:-$(id -un)}")" -- "$p" 2>/dev/null || { rmdir -- "$p" 2>/dev/null || true; return 1; }
    fi
    [ -d "$p" ] && [ ! -L "$p" ] && [ "$(stat -c %u -- "$p")" = "$job_uid" ]
}

# ci_child_reset PATH MOUNT: rule 2. Takes PATH, a DIRECT child of MOUNT (a mount's own root,
# root's), whatever it is, out of the way if the job's own uid owns it: it is MOVED into
# MOUNT/.trash (ci_trash_move, a rename), never removed here, because the caller holds the lock
# that keeps every other job out of it and other steps wait on that lock. The caller makes the
# name again (ci_child_make), lets its lock go and calls ci_trash_empty. Another uid's, a deeper
# path, a link (probe unlinks those) and a name that is still there after the move are left:
# return 1. NRV-W1204.
ci_child_reset() {
    local p="$1" mount="$2" was
    [ "$(dirname -- "$p")" = "${mount%/}" ] || return 1
    [ ! -L "$p" ] && [ -e "$p" ] || return 1
    [ "$(stat -c %u -- "$p")" = "$(ci_job_uid)" ] || return 1
    was=$(stat -c '%F, mode %a' -- "$p")
    ! ci_has_acl "$p" || was="$was, with an ACL"
    ci_trash_move "$p" || return 1
    [ ! -e "$p" ] || return 1
    ci_warning "NRV-W1204: $p, owned by the job's user (${CI_JOB_USER:-$(id -un)}), was not a usable directory for it (writable and searchable; was: $was): removed, to be made again (it is only a cache; a job's chmod, ACL or file); if this keeps happening, look for the script that does it"
}

# ci_child_ensure PATH MOUNT [LOCKCMD...]: PATH, a direct child of MOUNT, made a directory the job
# can use: probed, reset if it is the job's and unusable (after LOCKCMD, which takes the exclusive
# access that keeps other jobs out and must succeed; none when the caller already holds it), made
# if it is not there. NRV-E1228 if it still is not one. If LOCKCMD fails (a job that is running
# holds the lock shared), another step that was resetting the same child at the same time may
# have made it usable: LOCKCMD must leave the caller holding what it held before (the shared lock),
# and the child is probed once more before it is refused.
ci_child_ensure() {
    local p="$1" mount="$2" rc=0
    shift 2
    ci_child_probe "$p" || rc=$?
    if [ "$rc" = 11 ] && [ $# -gt 0 ]; then
        if "$@"; then
            if ci_child_reset "$p" "$mount"; then rc=10; fi
        else
            rc=0
            ci_child_probe "$p" || rc=$?
        fi
    elif [ "$rc" = 11 ] && ci_child_reset "$p" "$mount"; then rc=10; fi
    if [ "$rc" = 10 ] && ci_child_make "$p"; then rc=0; fi
    [ "$rc" = 0 ] || { ci_child_refused "$p"; return 1; }
}

# ci_child_refused PATH: NRV-E1228 for a direct child of a mount root.
ci_child_refused() {
    ci_error "NRV-E1228: $1 is not a directory that the job's user (${CI_JOB_USER:-$(id -un)}) can use, and the step could not make it one (another user's, or other jobs hold the lock a reset needs): on the host, rm -rf it (it is only a cache) and start the pipeline again"
}

# ci_cache_check ROLE ROOT: ROLE is main or branch. NRV-E1202 if ROOT is not laid out as above, or
# main's directory is writable where it must not be (a branch) or not where it must be (main), or
# branches/ is not writable in a branch's pipeline: the mount's, by root's test, whoever owns the
# directory. Then ci_mount_root (NRV-W1203, NRV-E1229) on the directory the job's caches are made in
# (main/ in main's role, branches/ in a branch's).
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
    if [ "$role" = main ]; then ci_mount_root "$root/main"; else ci_mount_root "$root/branches"; fi
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

# ci_job_dir PATH...: makes each PATH (parents first) a directory the job user can use, as the job
# user, never as root: PATH is below a direct child of a mount root (a branch's zig and zig-local),
# which is all the job's own tree, so whatever is at PATH that is no usable directory (a link, a
# file, a FIFO, a directory it cannot use) is the job's own doing: the job removes it
# (rm -rf --one-file-system, never following a link) and makes the directory again, NRV-W1204. A
# directory the job cannot remove or make (another user's: root makes none of these) is NRV-E1228.
ci_job_dir() {
    local p was
    ci_job_not_root ci_job_dir || return 1
    for p in "$@"; do
        if [ -e "$p" ] || [ -L "$p" ]; then
            if [ -L "$p" ] || [ ! -d "$p" ] || ! ci_job_usable "$p"; then
                was=$(stat -c '%F, mode %a' -- "$p" 2>/dev/null || echo unknown)
                ci_as_job rm -rf --one-file-system -- "$p" 2>/dev/null || true
                if [ ! -e "$p" ] && [ ! -L "$p" ]; then
                    ci_warning "NRV-W1204: $p, owned by the job's user (${CI_JOB_USER:-$(id -un)}), was not a usable directory for it (writable and searchable; was: $was): removed, to be made again (it is only a cache; a job's chmod, ACL, file or link)"
                fi
            fi
        fi
        if [ ! -e "$p" ] && [ ! -L "$p" ]; then ci_as_job mkdir -- "$p" 2>/dev/null || true; fi
        if [ -L "$p" ] || [ ! -d "$p" ] || ! ci_job_usable "$p"; then
            ci_error "NRV-E1228: $p is not a directory that the job's user (${CI_JOB_USER:-$(id -un)}) can use, and could not be made one (another user's directory): on the host, rm -rf it (it is only a cache) and start the pipeline again"
            return 1
        fi
    done
}

# ci_dir_gib DIR...: the size of the directories together, in GiB rounded up, counting blocks (not
# inodes: ci_disk_low watches those). A job made the trees, so the walk is bounded by
# CI_BRANCH_DU_SECONDS (default 60, timeout(1)) and a walk that does not end in time prints 999999:
# over every bound. Never call it with the branches' lock (fd 7) or main's (fd 9) held, except for
# a tree a step is about to copy, whose size is its own business (ci_branch_prepare, the seed).
ci_dir_gib() {
    local out rc=0
    out=$(timeout "${CI_BRANCH_DU_SECONDS:-60}" du -s -B1G "$@" 2>/dev/null) || rc=$?
    if [ "$rc" = 124 ]; then echo 999999; return 0; fi
    printf '%s\n' "$out" | awk '{n += $1} END {print n + 0}'
}

# ci_disk_low DIR MIN_GIB: whether the file system of DIR has less than MIN_GIB GiB free, or fewer
# than CI_MIN_FREE_INODES (default 100000) inodes free (df -Pi). A job can exhaust the inodes with
# empty files, which cost no blocks, so the GiB test alone would never call the box low. A file
# system that reports no inode count (0 or "-": btrfs, for one) has no inode test.
ci_disk_low() {
    local avail ifree itotal
    avail=$(df --output=avail -B1G "$1" | tail -1 | tr -d ' ')
    [ "$avail" -ge "$2" ] || return 0
    read -r itotal ifree < <(df -Pi "$1" | awk 'NR == 2 {print $2, $4}')
    [[ "${itotal:-}" =~ ^[0-9]+$ ]] && [[ "${ifree:-}" =~ ^[0-9]+$ ]] && [ "$itotal" -gt 0 ] || return 1
    [ "$ifree" -lt "${CI_MIN_FREE_INODES:-100000}" ]
}

# ci_branch_size LOCKS KEY: the size in GiB last measured for a branch's cache (ci_branch_measure),
# 0 if there is none. Read under the branches' lock instead of walking the tree.
ci_branch_size() {
    local n
    n=$(cat -- "$1/$2.size" 2>/dev/null) || n=0
    [[ "$n" =~ ^[0-9]{1,6}$ ]] || n=0
    echo "$n"
}

# ci_branch_measure LOCKS KEY DIR: measures DIR, this step's own cache, and records its size in
# LOCKS/KEY.size (root's, in the lock directory; written whole and renamed). Called with the
# branches' lock let go and only the key's own (shared) held, so the walk stalls nobody, and
# bounded (ci_dir_gib: a timeout is recorded as over every bound). The next prune, or the next step
# of this branch, reads the number under the lock and drops a cache that is over the bound.
ci_branch_measure() {
    local f="$1/$2.size"
    ci_dir_gib "$3" >"$f.new" 2>/dev/null && mv -f -- "$f.new" "$f" 2>/dev/null || true
}

# ci_branch_prune BRANCHES LOCKS KEEP MAXN MAXDAYS MAXGIB: drops the branch caches nobody is using
# (no job holds its lock) that are beyond the MAXN most recent, older than MAXDAYS days or larger
# than MAXGIB GiB (as ci_branch_measure last recorded it: nothing here walks a tree). KEEP, the
# caller's own, is never dropped and counts against MAXN. Call with the branches lock held. It only
# DECIDES and RENAMES: a dropped cache is moved into BRANCHES/.trash (ci_trash_move), and the
# caller removes the trash (ci_trash_empty) after it has let the lock go. The bound counts blocks;
# the box-wide low-disk prune (CI_BRANCH_PRUNE_ALL) also watches inodes (ci_disk_low).
ci_branch_prune() {
    local b="$1" locks="$2" keep="$3" maxn="$4" maxdays="$5" maxgib="$6" rec d name n=0 drop
    # KEEP takes one of the MAXN places (it is made right after, if it is not there yet), so MAXN
    # is the most there are, KEEP included.
    n=1
    ci_trash_ready "$b" || return 0 # E1236 once; nothing is dropped, and the step goes on
    for d in "$b"/*.partial.*; do # a killed seed's; seeds run under the lock
        if [ -e "$d" ] || [ -L "$d" ]; then ci_trash_move "$d" 2>/dev/null || true; fi
    done
    # Names come NUL-separated from find, never from parsing ls: a job can name a directory with a
    # newline in it, and a line of that name would be taken for a path. A name that is not one
    # ci_branch_key makes, or is not a real directory, is the job's own doing and is removed (a
    # link is unlinked, not followed), with no lock: no job's cache is called that.
    while IFS= read -r -d '' rec; do
        name=${rec#* }
        [ "$name" != "$keep" ] || continue
        if ! [[ "$name" =~ ^b-[A-Za-z0-9._-]+$ ]] || [ -L "$b/$name" ] || [ ! -d "$b/$name" ]; then
            ci_trash_move "$b/$name" 2>/dev/null || true
            continue
        fi
        d="$b/$name"
        n=$((n + 1))
        drop=no
        [ "$n" -le "$maxn" ] || drop=yes
        [ -z "$(find "$d" -maxdepth 0 -mtime +"$maxdays" 2>/dev/null)" ] || drop=yes
        [ "$(ci_branch_size "$locks" "$name")" -le "$maxgib" ] || drop=yes
        [ "$drop" = yes ] || continue
        (
            # Made by ci_lock_file: 0600, never followed, in the step's own lock directory.
            ci_lock_file "$locks/$name.lock" || exit 1
            exec 5>>"$locks/$name.lock"
            # The lock file stays: unlinking it would let a job that opened it first keep a lock
            # on an inode no later prune opens. They are empty, one per branch key.
            flock -x -n 5 && ci_trash_move "$d" && rm -f -- "$locks/$name.size"
        ) 2>/dev/null || true
    done < <(find "$b" -mindepth 1 -maxdepth 1 -name 'b-*' -printf '%T@ %f\0' 2>/dev/null | sort -z -rn)
}

# ci_branch_own_lock KEY LOCKED: a shared lock on fd 6 (the branch's own lock, opened by the caller),
# waiting at most CI_LOCK_WAIT seconds; NRV-E1225 if it is not free (return 1; the branches' lock on
# fd 7 is let go, if LOCKED is yes). If LOCKED is yes the lock is first tried without waiting: if it
# is not free, fd 7 and main's lock (fd 9) are let go BEFORE the bounded wait, so that nobody
# waits behind a wait (the branch then starts unseeded, as one that never got fd 7), and the
# return is 2 (got it, but the caller no longer holds fd 7).
ci_branch_own_lock() {
    local rc=0
    if [ "$2" = yes ] && ! flock -s -n 6; then
        flock -u 7
        flock -u 9 2>/dev/null || true
        rc=2
    fi
    flock -s -w "${CI_LOCK_WAIT:-300}" 6 || {
        ci_error "NRV-E1225: $1's own cache lock was held for ${CI_LOCK_WAIT:-300} s: another step's prune of this branch's cache (it holds the lock exclusively while it removes it; see NRV-W1202), or a process on the host, holds it; lslocks on the host shows its pid; if the holder is just slow, raise CI_LOCK_WAIT"
        [ "$2" != yes ] || flock -u 7
        return 1
    }
    return "$rc"
}

# ci_branch_prepare ROOT BRANCH: creates this branch's cache (zig/p, the fetched packages, a copy of main's, if that is no
# larger than CI_BRANCH_SEED_MAX_GIB; zig-local/ empty), prunes the others, and holds a shared lock on its own on
# fd 6 for the rest of the process, so a prune by another job leaves it alone. Sets CI_BRANCH_DIR.
# The count, age and size of branch caches are bounded: CI_BRANCH_CACHES (8), CI_BRANCH_CACHE_DAYS
# (7), CI_BRANCH_CACHE_MAX_GIB (12). With CI_BRANCH_PRUNE_ALL=1 (the disk is low) every cache
# nobody is using goes. The lock on fd 7 (locks/branches.lock) serialises seeding and pruning; fd 6 is
# taken before it is released, so no prune falls between.
ci_branch_prepare() {
    local root="$1" key b dir locks maxn maxdays maxgib seedgib seed_size partial err last rc locked=no own_rc
    ci_knobs_check || return 1
    key=$(ci_branch_key "$2")
    b="$root/branches"
    dir="$b/$key"
    locks="$root/locks"
    maxn="${CI_BRANCH_CACHES:-8}"
    maxdays="${CI_BRANCH_CACHE_DAYS:-7}"
    maxgib="${CI_BRANCH_CACHE_MAX_GIB:-12}"
    seedgib="${CI_BRANCH_SEED_MAX_GIB:-6}"
    [ "${CI_BRANCH_PRUNE_ALL:-}" != 1 ] || maxn=0
    # The size of main's package cache decides whether this branch is seeded from it. It is
    # measured here, before the branches' lock: a walk of a tree under that lock would stall every
    # other branch's step (the design rule at the top). Only a branch with no directory yet needs it.
    seed_size=
    if [ ! -e "$dir" ] && [ -d "$root/main/zig/p" ]; then seed_size=$(ci_dir_gib "$root/main/zig/p"); fi
    ci_lock_file "$locks/branches.lock" || return 1
    { exec 7>>"$locks/branches.lock"; } 2>/dev/null || { ci_lock_open_failed "$locks/branches.lock" '>>'; return 1; }
    if flock -x -w "${CI_LOCK_WAIT:-300}" 7; then
        locked=yes
        ci_branch_prune "$b" "$locks" "$key" "$maxn" "$maxdays" "$maxgib"
        # Its own cache over the size limit (as the last step recorded it, ci_branch_measure: no
        # walk here) starts again, if no job of this branch is using it: moved aside, removed below.
        if [ -d "$dir" ] && [ "$(ci_branch_size "$locks" "$key")" -gt "$maxgib" ]; then
            (
                ci_lock_file "$locks/$key.lock" || exit 1
                exec 5>>"$locks/$key.lock"
                flock -x -n 5 && echo "branch cache $key is over $maxgib GiB: starting again" >&2 && ci_trash_move "$dir" && rm -f -- "$locks/$key.size"
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
    own_rc=0
    ci_branch_own_lock "$key" "$locked" || own_rc=$?
    [ "$own_rc" != 1 ] || return 1
    [ "$own_rc" != 2 ] || locked=no # not free at once: fd 7 and fd 9 were let go before the wait
    # This branch's directory (rules 2 and 3 at the top): probed, its tree normalized by the job
    # (ci_child_probe). One the job owns and cannot use, whatever it is (a directory with a chmod,
    # an ACL or a tree that cannot be normalized; a file, a FIFO, a socket), is removed and made
    # again (NRV-W1204) under the key's lock held exclusively, as a prune holds it: ours is let go
    # first (a second descriptor's exclusive lock would wait for it), and taken again after. If
    # another job of the branch holds it, nothing is removed and NRV-E1228 (or E1214) says so below.
    rc=0
    if [ -d "$dir" ] && [ ! -L "$dir" ] && [ "$(stat -c %u -- "$dir" 2>/dev/null)" = "$(ci_job_uid)" ]; then
        # The job's own directory is there, so nothing is seeded: the probe (the job's walk of the
        # tree, bounded by CI_NORMALIZE_SECONDS, minutes for a poisoned one) needs neither the
        # branches' lock (fd 7) nor main's (fd 9, the caller's), and holding them across it would
        # stall every other branch's step (NRV-W1202) and main's prune. Our own shared lock (fd 6)
        # keeps every prune off this directory. A directory that then must be reset starts empty:
        # the seed needs main's lock, which is not held any more (the branch refills it).
        [ "$locked" != yes ] || { flock -u 7; locked=no; }
        flock -u 9 2>/dev/null || true
    fi
    ci_child_probe "$dir" || rc=$?
    if [ "$rc" = 11 ]; then
        flock -u 6
        ( { exec 5>>"$locks/$key.lock"; } 2>/dev/null && flock -x -n 5 && ci_child_reset "$dir" "$b" ) || true
        own_rc=0
        ci_branch_own_lock "$key" "$locked" || own_rc=$?
        [ "$own_rc" != 1 ] || return 1
        [ "$own_rc" != 2 ] || locked=no
        rc=0
        ci_child_probe "$dir" || rc=$?
    fi
    if [ "$rc" = 10 ]; then
        # Root makes the direct children of $b (rule 1: it is root's, so nothing root does there can
        # follow a link); what is below them is made by the job's user (ci_as_job). The partial
        # directory has a name of mktemp's, made with O_EXCL, and is the job's from the start.
        partial=
        if [ "$locked" = yes ] && partial=$(mktemp -d "$b/$key.partial.XXXXXX" 2>/dev/null); then
            chown -h "$(ci_job_uid):$(id -g "${CI_JOB_USER:-$(id -un)}")" -- "$partial" 2>/dev/null || { rmdir -- "$partial" 2>/dev/null || true; partial=; }
        fi
        if [ -n "$partial" ]; then
            # Only zig/p, the fetched packages, is copied: they are content-addressed and written
            # once. Main's other global-cache files and its zig-local are rewritten by main's jobs,
            # which hold main's lock shared, as this job does (the shared flock in the step script):
            # nothing keeps them out while this copies, so a copy could keep a torn file for days.
            # They start empty and fill themselves. A plain copy: a hard link would let a branch
            # write main's inode.
            ci_as_job mkdir "$partial/zig"
            if [ ! -d "$root/main/zig/p" ]; then
                echo "main has no package cache yet: branch $key starts empty" >&2
            elif [ -z "$seed_size" ]; then
                # The directory was dropped after the size was taken (or was not there to measure):
                # no walk under the lock, so it starts empty.
                echo "branch $key starts empty (the size of main's package cache was not measured)" >&2
            elif [ "$seed_size" -le "$seedgib" ]; then
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
            # Root renames one name in its own directory: nothing inside $partial is followed. A
            # seed that lost the race is moved aside, not removed (fd 7 is held; ci_trash_empty below).
            mv -T "$partial" "$dir" 2>/dev/null || ci_trash_move "$partial" || true
        else
            # No lock on the branches' directory (or no partial directory could be made): no
            # shared partial directory a prune could remove. It starts empty.
            ci_child_make "$dir" || true
        fi
    fi
    # The branches' lock is let go before anything can return: seeding is done, or never started.
    # So is main's (fd 9, the caller's: nothing after this reads main's cache). Only then does root
    # remove what the prune and a reset moved aside: no lock another step waits on is held.
    [ "$locked" != yes ] || flock -u 7
    flock -u 9 2>/dev/null || true
    ci_trash_empty "$b"
    # Whichever way $dir was made (or not), it must be a directory now.
    if [ -L "$dir" ] || [ ! -d "$dir" ]; then
        if [ -e "$dir" ] || [ -L "$dir" ]; then
            ci_error "NRV-E1214: $dir is not a directory: remove it (another user's, or other jobs of this branch hold the lock that removing it needs)"
        else
            ci_error "NRV-E1214: $dir could not be made in $b (a full disk, or $b not root-owned and writable by the step; NRV-W1203 repairs that): free space or check $b on the host"
        fi
        return 1
    fi
    # Another user's directory, or one the job cannot use that other jobs hold the lock of: NRV-E1228.
    # (rc 11 here: the job's own tree could not be normalized and could not be reset either.)
    if [ "$rc" = 11 ] || [ "$(stat -c %u -- "$dir")" != "$(ci_job_uid)" ] || ! ci_job_usable "$dir"; then
        ci_child_refused "$dir"
        return 1
    fi
    # The job's own directories below it, as the job user: a missing one is made, a link, a file or
    # an unusable one is replaced (NRV-W1204). Nothing in $dir is root's to touch.
    ci_job_dir "$dir/zig" "$dir/zig-local" || return 1
    ci_as_job touch "$dir"
    ci_branch_measure "$locks" "$key" "$dir" # only the key's own shared lock is held here
    # shellcheck disable=SC2034 # read by ci/woodpecker_step.sh
    CI_BRANCH_DIR="$dir" # not printed: a command substitution would drop the lock with its shell
}

# ci_main_prune ROOT MIN_GIB: empties main's Zig caches (never the pinned toolchain) when the box
# is low on space (under MIN_GIB GiB free, or too few inodes: ci_disk_low) and the lock on fd 9
# (locks/main.lock) is free: every job holds it
# shared while it runs, so this is called before the caller takes its own shared lock, which it
# takes after, pruned or not. One pruner per push is enough, so the wait is short (CI_PRUNE_WAIT,
# default 5 s) and, once it ends (lock taken or not), space is measured again: if another job has
# freed it, nothing is pruned and nothing is warned. NRV-W1202 only if space is still low and the
# lock was not free. It only RENAMES the two caches into main/.trash while it holds the lock
# (ci_trash_move); the caller removes them (ci_trash_empty) once the lock is shared again.
ci_main_prune() {
    local root="$1" min="$2" wait="${CI_PRUNE_WAIT:-5}" got=no p
    flock -x -w "$wait" 9 && got=yes
    if ! ci_disk_low "$root/main" "$min"; then
        echo "main's cache: space is free again, not pruning"
    elif [ "$got" = yes ]; then
        echo "emptying main's Zig caches (no other job holds them)"
        for p in zig zig-local; do # a link there is moved as the link, not followed
            if [ -e "$root/main/$p" ] || [ -L "$root/main/$p" ]; then ci_trash_move "$root/main/$p" || true; fi
        done
    else
        ci_warning "NRV-W1202: other jobs held main's cache for $wait s: not pruned. To recover by hand, with the agent idle: rm -rf /var/cache/nerva-ci/main/zig-local /var/cache/nerva-ci/main/zig"
    fi
}

# ci_main_exclusive: main's lock exclusively (converted from the shared one the caller holds),
# waiting at most CI_PRUNE_WAIT seconds, as the prune does. If that fails the shared lock is
# taken again (a failed conversion loses it) and the return is 1.
ci_main_exclusive() {
    flock -x -w "${CI_PRUNE_WAIT:-5}" 9 && return 0
    ci_shared_lock
    return 1
}

# ci_main_prepare ROOT USER LOW MIN_GIB: the main role's cache set-up, run as root, in this order:
# the lock file (ours, 0600) and its fd 9, the prune (when LOW is yes), and only then main's
# directories (zig, zig-local, tools), direct children of main/, which is root's (rule 1): made and
# chowned to USER by root, or reset by root if USER's and unusable (ci_child_ensure). The prune
# removes main/zig and main/zig-local, so the directories come after it. Main's lock is held
# SHARED from before the first probe to the return (the caller takes it again, which is no
# change): `reset-cache main` takes it exclusively and moves zig and zig-local aside, so a probe, a
# normalization or a make that ran without it could meet a directory that vanished (NRV-E1228).
# Exclusive only for a reset below (the lock is converted, which loses the shared one if that
# fails, so every probe takes the shared one again first, and ci_main_exclusive takes it again
# after a failure), and for the prune above. A reset under it is a rename (ci_child_reset), so
# two steps that find the same child poisoned at once do not refuse each other: the loser fails to
# get the exclusive lock while the winner's job runs, and probes again, which finds the child the
# winner made. What can still refuse a step (NRV-E1228) is a child that needs a reset while a
# running main job, one that is not itself resetting it, holds the lock shared.
ci_main_prepare() {
    local root="$1" CI_JOB_USER="$2" low="$3" min="$4" p
    ci_main_lock_open "$root" || return 1 # root's, in the lock directory a job cannot write
    [ "$low" = no ] || { echo "Below $min GiB free"; ci_main_prune "$root" "$min"; }
    # Rule 2 for main's direct children: one the job owns and cannot use, of any type, is removed
    # under main's exclusive lock (what the prune takes; waits as the prune does) and made again by
    # root with a chown (NRV-W1204); one that is missing is made; another user's is refused
    # (NRV-E1228). The job's tree below them is normalized by ci_child_probe. Lock order: main's
    # lock, then the children lock (ci_child_probe, ci_child_make), as `reset-cache` takes them.
    for p in zig zig-local tools; do
        ci_shared_lock || return 1
        ci_child_ensure "$root/main/$p" "$root/main" ci_main_exclusive || return 1
    done
    ci_shared_lock || return 1
    # Whatever the prune and the resets moved aside is removed now, with main's lock shared again
    # (every step holds it so for its whole run): root never walks a job's tree under the
    # exclusive lock.
    ci_trash_empty "$root/main"
}
