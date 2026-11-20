---
id: O4
date: 2026-11-20
area: CI
amends: P285, P147e
---

# Self-hosted CI: steps are not privileged, and only a push to main writes the shared caches

NervaOrg/nerva#4 puts a self-hosted Woodpecker (`ci.botpike.com`, one box) beside GitHub Actions.
GitHub's runners are fresh per job; this box is not, so what a job leaves behind reaches the next
one. This decision draws the trust boundary of that box and the rule for its caches.

## Decision

**1. No step is privileged.** No `.woodpecker/*.yaml` has `privileged: true`, and the repository is
not Trusted for *security*. A step runs as root in its container with Docker's default
capabilities (enough for `chown`, `useradd` and `setpriv`, which `ci/woodpecker_step.sh` uses to
run the job as the unprivileged user `ci`), and no capability is added. Nerva's IO is io_uring,
which Docker's default seccomp profile refuses (Docker 25 and later). Instead of lifting every
protection from every step, the box's Docker daemon carries a seccomp profile that is Docker's
default plus `io_uring_setup`, `io_uring_enter` and `io_uring_register` (`ops/ci/docker/`), which
`ops/ci/woodpecker-bootstrap.sh` installs through `daemon.json` (idempotent, merging, one Docker
restart). `ci/io_uring_check.sh` still runs before every job and fails with NRV-E1201 if the
daemon refuses io_uring, so a box without the profile says so. The profile applies to every
container on that daemon without a profile of its own; the box runs CI and nothing else.

**2. Only a pipeline for a push to main writes a shared cache.** The caches are `main/`
(`tools/`, the pinned Zig's archive named by its sha256; `zig/`; `zig-local/`) and
`branches/<key>/` under `/var/cache/nerva-ci`.

- A step for a push to main mounts `main/` writable and `branches/` not at all. Any other step
  (another branch, a manual run, a cron run, a run of main that is not a push) mounts `main/`
  read-only (`:ro`) and `branches/` writable. The two steps of each workflow are exclusive by
  `when:` (`event: push, branch: main` against its negation), so no pipeline gets both.
- A branch has its own caches: a plain copy of main's global Zig cache (`zig/`; not `zig-local/`,
  which a build of main may be writing, so a branch starts it empty) made when the branch's cache is
  first needed (not made if main's is over 6 GiB; the branch then starts empty), bounded in count
  (8), age (7 days) and size (12 GiB each), pruned under a lock that skips a cache another job is
  using. Nothing a branch writes is read by main. A branch's cache is not shielded from other
  branches (see "What remains trusted").
- The toolchain is never trusted by name. Every use copies the archive from `main/tools/<sha256>.tar.xz`
  into the job's own `zig/cache` and runs `zig/download.sh`, which checks it against the sha256
  pinned in the repository and downloads it again on a mismatch (NRV-W1201). Each job unpacks into
  its own tree, so two jobs share nothing mutable and nothing races. Only a push to main writes
  the archive, and only after verifying it.
- `ci/woodpecker_step.sh` checks that the mounts are the ones its role needs (NRV-E1202), so a
  workflow file edited the wrong way round fails instead of running.

**3. What the mounts do and do not stop.** The mount is enforced by Docker, not by a script the
job can edit, so a job that behaves cannot write main's cache by mistake or by a bug, and a
compromised *dependency or test* that runs inside a branch's job cannot. **A branch cannot be
stopped from bypassing it on purpose:** the branch controls its own `.woodpecker/*.yaml` and
`ci/` scripts, and the repository is Trusted for *volumes* (every workflow mounts a host
directory), so a pusher can write a step that mounts `main/` writable, or any host path. Trusted
volumes cannot be limited per branch. The per-branch caches limit what an accident or a leaked
branch cache can do; they are not a defence against a pusher with bad intent. The remedy, if that
is ever needed, is to untrust *volumes* and have the agent mount the cache itself
(`WOODPECKER_BACKEND_DOCKER_VOLUMES`), which gives every branch the same mounts, so the main/branch
split would have to move to separate agents with separate labels. It is not done here: it cannot
be tested without the server.

## What remains trusted

**Anyone who can push a branch to the repository can run code on the CI box, as root in a container
with Docker's default capabilities, on the host's network when the step asks for it, and with
`main/`'s cache and the host's Docker socket if the step mounts them.** Fork pull requests never run
(Allow pull requests is off; the workflows match `push` and `manual` only). The Jepsen workflow
mounts the host's Docker socket, which is root on the box in all but name, for the five node
containers it drives; it runs for a push to a `jepsen/**` branch or a manual run, and so for anyone
who can push one. **A job can write every branch's cache, not only its own:** `branches/` is
mounted writable in every step that is not for main, and each `branches/<key>/` belongs to the same
`ci` user, so a compromised dependency or test in branch X's job can decide what branch Y's next
run executes. Separate users or mounts per branch would be needed to stop it; it is not done. Main's
cache holds only what a push to main built, but a pusher who bypasses the
mount can plant entries main's builds then use: releases are built by GitHub's `release.yml`, not
here, so this reaches main's CI result, not a release. The owner decides who has write access to the
repository, and that is the trust boundary of this box.

## Why

- `privileged: true` gave every step, including every branch's, all capabilities, no seccomp and
  every host device, for the sake of three syscalls. The daemon profile gives exactly those three.
- One shared cache written by every branch (the first design) let a push to any branch change what
  the next job on main found, with no check. Per-branch caches, a read-only main and a verified
  toolchain remove the ways that happens without anyone trying.
- Where a rule cannot be enforced against a pusher, this record says so, rather than showing the
  mounts as a wall.

## What it costs

- A cold branch's first run copies main's global Zig cache `zig/` (up to 6 GiB) and starts with an
  empty `zig-local/`, where most build artifacts go: its first run is close to cold, and its second
  is as warm as the branch's own first.
- Disk: at most 8 branch caches of 12 GiB beside main's. `ci/woodpecker_step.sh` empties the unused
  ones when the free space is low; the manual recovery is in `ops/ci/README.md`.
- Docker restarts once when the profile is installed (running pipelines fail; the owner runs the
  bootstrap with the agent idle). The profile must be refreshed by hand when Docker's default
  changes (`ops/ci/docker/README.md`).
- Each workflow has two steps instead of one.
- The longest jobs have 75 minutes (330 for the long searches) instead of GitHub's 30 to 60: a
  push runs 16 workflows at once on one box with the simulator fleet beside them, and pipeline 12's
  `check-scripts` and `targets` ended at the old 30. `check-scripts` is also split in two
  (`check-scripts`, `check-packages`) so the package repositories' tests (about 23 minutes alone)
  run beside the rest.
