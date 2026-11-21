---
id: O12
date: 2026-11-21
area: CI
amends: O4
---

# The integration job runs alone on the Woodpecker box, behind a reader/writer lock

NervaOrg/nerva#12 (fixes #11). `test:integration` asserts that the median of 50 lookups takes less
than one tick (10 ms) of wall time (`src/integration_tests.zig`). On the Woodpecker box every
workflow of a pipeline runs at once, with other pipelines beside them: the median measured 6.6,
9.3 and 17.4 ms in different runs, and once even the fastest of 50 took 11.9 ms. Alone, the same
commit measures 2.1 ms. The test and its bound are right; the box's scheduling was wrong.

## Decision

**1. A host-wide reader/writer lock.** `ci_box_lock` (`ci/cache.sh`), called at the top of
`ci/woodpecker_step.sh` before any package install, takes `locks/box.lock` (fd 10) for the step's
whole run: **shared** for every job, **exclusive** for `integration`. Jobs run side by side as before;
integration runs with no other job on the host, from the moment it holds the lock.

**2. A turnstile against starvation.** flock is not fair: shared steps arriving one after another
would keep an exclusive waiter out for ever. Every step first takes `locks/turnstile.lock` (fd 11)
exclusively. A shared step lets it go as soon as it holds `box.lock`; the integration step holds it
while it waits for `box.lock` and for its whole run, so no job starts behind it. The order is always
turnstile, then box, so no cycle is possible.

**3. Bounded, and never silent.** Each wait is `flock -w "$CI_BOX_WAIT"` (default 5400 s, as
`CI_JEPSEN_WAIT`; validated by `ci_knobs_check`, NRV-E1208). A timeout fails the step with NRV-E1245;
the test is never run without the lock. The wait is before the job, so it counts in the step's time
(`ci_job_seconds` and `ci_tail_seconds` count from `CI_STEP_START`, NRV-W1207, NRV-E1215): a wait
that leaves the job less time shortens its limit or, with under 60 s left, fails it as they already
say. A bad mode is NRV-B1203.

**4. Jepsen takes the lock shared.** It is not exempt: its load (Docker containers and load
generators) is what integration must not run beside. It takes `box.lock` before its own lock, so a
Jepsen run queued behind another holds `box.lock` shared while it waits, and integration waits for
it too (bounded by `CI_BOX_WAIT`). No cycle: nothing holding the Jepsen lock waits for the box lock.

**5. The step closes fds 10 and 11 for the job's user,** as it closes 6 to 9 (`install_zig`, the root
tests and the job). The descriptors are numbered 10 and 11 because 3 to 9 are used by the other locks;
they are opened with a bare `exec`, never inside a `{ ...; } 2>/dev/null` group, which uses the
first free descriptor from 10 up to save stderr and would close them again.

## Reason

The cheapest fix that keeps the test honest: the bound stays at one tick, the test stays the same,
and the box stops measuring itself under load. Putting the lock at the top, not before the job, also
keeps the other jobs' `apt-get` (all 16 workflows do it at once) out of the integration window.

## What it costs

- Integration waits for every job already running, a 330-minute `fuzz-long` or `vopr-long` included
  (it fails NRV-E1245 after `CI_BOX_WAIT`; start it again, or raise the knob). Other jobs wait for
  the integration job while it waits and runs (about 20 s of test plus its build).
- The exclusive window includes the integration step's own package install and the build of the test
  binary: `ci/job.sh` runs `zig build test:integration` in one command, so building first, under the
  shared lock, needs a change there (open PR #9 changes that file). Not done; a later change can.
- Markdown-only runs (N68) take the lock too, for the time of the check.
- The scheduling is not verified on the real box from here (see the pull request).
