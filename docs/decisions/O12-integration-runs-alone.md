---
id: O12
date: 2026-11-21
area: CI
amends: O4
---

# The integration test runs without the other short jobs beside it, behind a reader/writer lock

NervaOrg/nerva#12 (fixes #11). `test:integration` asserts that the median of 50 lookups takes less
than one tick (10 ms) of wall time (`src/integration_tests.zig`). On the Woodpecker box every
workflow of a pipeline runs at once, with other pipelines beside them: the median measured 6.6,
9.3 and 17.4 ms in different runs, and once even the fastest of 50 took 11.9 ms. Alone, the same
commit measures 2.1 ms. The test and its bound are right; the box's scheduling was wrong.

An earlier version of this decision made integration wait for every job on the host, the 330-minute
`fuzz-long` and `vopr-long` searches and Jepsen included. The review (6008872330) showed that this
turned a flaky red into a certain red with a 90-minute stall for every new job while a long search ran.
This is the reworked decision (the owner's: 2026-11-22); O12 was not merged before.

## Decision

**1. Two kinds of job.** The *long* jobs, `fuzz-long`, `vopr-long` and `jepsen` (`ci/woodpecker_step.sh`,
`box=none`), take no lock and never wait for one. Every other job is *short* (75 minutes at most: its own
step limit; about 25 minutes for the longest, `check-packages`).

**2. A host-wide reader/writer lock around the run alone.** `ci_box_lock` and `ci_box_unlock`
(`ci/cache.sh`) take and release `locks/box.lock` (fd 10) around the job's run, `ci_step_job`, and
nothing else: not the `apt-get`, the seed copy, `install_zig`, nor the tail (`ci_step_finish`), which
run with no box lock. A short job holds it **shared**, so short jobs run side by side as before. The
`integration` job runs twice in the step: its build (`ci/job.sh integration-build`, a `zig build`
that fills the cache) under the shared lock, so that no other integration test runs beside a build,
then its test (`ci/job.sh integration`) **exclusive**, which waits for the running short jobs to end.
A Markdown-only run (N68) exits before the job and takes no lock.

**3. A turnstile against starvation.** flock is not fair: shared steps arriving one after another would
keep an exclusive waiter out for ever. Every call first takes `locks/turnstile.lock` (fd 11)
exclusively. A shared call lets it go as soon as it holds `box.lock`; the exclusive call holds it while
it waits for `box.lock` and for its whole run, so no short job starts behind it. The order is always
turnstile, then box.

**4. No deadlock on the upgrade.** A step never waits for the turnstile or for an exclusive lock while it
holds `box.lock` shared: two integration steps would each hold shared and wait for the other. The
integration step releases the shared lock (build done), then takes the turnstile, then `box.lock`
exclusive, runs the test, and releases both. `ci_box_lock` refuses a call made while the step holds the
lock (`CI_BOX_HELD`: NRV-B1203).

**5. Bounded, and never silent.** Each wait is `flock -w "$CI_BOX_WAIT"`. The default is 4800 s: the
short jobs' step limit (75 minutes) and five more, so a wait only times out when a job outlived its own
limit. A timeout fails the step with NRV-E1245 (its message names who holds what: the integration step
that holds the turnstile, or the short jobs that hold the box); the test is never run without the lock.
The exclusive test run is itself bounded by `CI_INTEGRATION_RUN_MINUTES` (default 15, capped by the
step's limit), not the 75 minutes: what every short job waits behind is a test of about 20 s plus
the errors and recover tests, and a hung one must not stall the box for an hour. Both knobs are validated by
`ci_knobs_check` (NRV-E1208).

**6. The wait is accounted like other pre-job time.** The waits happen between `CI_STEP_START` and
`ci_step_job`, so `ci_job_seconds` and `ci_tail_seconds` count them as they count the `apt-get` before
(NRV-W1207, NRV-E1215). A short job's limit is 75 minutes and `ci_job_seconds` shortens a job only when the
step has used more than 360 minutes - 120 s - 300 s - 60 s - 75 minutes, about 277 minutes. A short job
waits at most `CI_BOX_WAIT` at the turnstile (it then holds it, so the box is free of exclusive holders
and its second wait is immediate); an integration step waits at most twice (the turnstile, then the
running jobs): 2 x 4800 s = 160 minutes at the very worst, which still leaves its build and its test their
full limits inside the repository's 360 minutes. The long jobs wait for nothing, so a 330-minute
search is never shortened by this lock.

**7. The step closes fds 10 and 11 for the job's user,** as it closes 6 to 9 (`install_zig`, the root
tests and the job): a job must not be able to hold a lock for good. That is why the switch from shared
to exclusive is made by the root step between two job invocations, never inside the job. The descriptors
are numbered 10 and 11 because 3 to 9 are used by the other locks; they are opened with a bare `exec`,
never inside a `{ ...; } 2>/dev/null` group, which uses the first free descriptor from 10 up to save
stderr and would close them again. `ci/ci_test.sh` runs a stub job and root tests with 9, 10 and 11
open and sees them closed, and kills a lock's holder to see the lock freed.

## Accepted: what the lock does not cover

- **Integration may still fail on timing while a long search or Jepsen runs beside it.** They are the
  jobs with a schedule and a slot of their own (the `fuzz-long` cron, set in Woodpecker's Settings, Cron,
  not in the repository; a hand-started `vopr-long`; a Jepsen run), and making integration wait hours
  for them, and every other job with it, is worse than a rare red. A red on timing during a long
  search is run again when it ends. Moving the long jobs off the box with #9's `tier` labels would
  remove this and is the follow-up.
- **The simulator fleet** (`ops/sim-fleet`, `CPUWeight=idle`) takes no lock. It yields CPU time and
  disk but not cache or memory bandwidth. The 2.1 ms measurement does not say whether the fleet was
  running; it is not verified here.
- **Other steps' pre-job and tail work** (`apt-get`, a branch's seed copy, trash removal) runs beside the
  exclusive test, as it runs beside everything: only the jobs' runs are covered.
- **Jepsen's node containers** belong to the host's Docker daemon: a cancelled Jepsen step can leave
  them running. Jepsen takes no lock in any case.
- **Steps from a commit without this change** (an open branch not rebased) take no lock.
- The exclusive window still includes what `zig build test:integration` compiles beyond `zig build`
  (the test executable and the build with commit-key deduplication off, used by the errors test): the
  scheduling is measured in `worklog/O12.md`, not on the real box.
- The scheduling is not verified on the real box from here (see the pull request).

## Reason

The cheapest fix that keeps the test honest: the bound stays at one tick and the test stays the same,
while the short jobs, which finish in minutes, stop running beside it. The long jobs cannot be waited
for. The lock covers only runs so that the window everyone waits behind is a test, not an `apt-get`, a
cache copy or a trash walk.

## What it costs

- Integration waits for the short jobs already running (up to their limits; about 25 minutes for the
  longest in practice), and they wait behind it while it waits and runs: a few minutes. A hung short job
  holds integration up to `CI_BOX_WAIT` and then fails it NRV-E1245.
- Integration's build needs `ci/job.sh integration-build` (one line; open PR #9 changes other lines of the file).
- A red integration beside a long job, as above.
