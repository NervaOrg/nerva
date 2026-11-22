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
commit measures 2.0 to 2.3 ms. The test and its bound are right; the box's scheduling was wrong.

An earlier version of this decision made integration wait for every job on the host, the 330-minute
`fuzz-long` and `vopr-long` searches and Jepsen included. The review (6008872330) showed that this
turned a flaky red into a certain red with a 90-minute stall for every new job while a long search ran.
The second version (review 6012650944) held the turnstile for the whole exclusive run, with waits that
did not add up. This is the third; O12 was not merged before.

## Decision

**1. Two kinds of job.** The *long* jobs, `fuzz-long`, `vopr-long` and `jepsen` (`ci/woodpecker_step.sh`,
`box=none`), take no lock and never wait for one. Every other job is *short* (75 minutes at most: its own
step limit; about 25 minutes for the longest, `check-packages`).

**2. A host-wide reader/writer lock around the run alone.** `ci_box_lock` and `ci_box_unlock`
(`ci/cache.sh`) take and release `locks/box.lock` (fd 10) around the job's run and nothing else: not
the `apt-get`, the seed copy, `install_zig`, nor the tail (`ci_step_finish`). A short job holds it
**shared**, so short jobs run side by side as before (`ci_step_job_in_box`). The `integration` job
(`ci_step_integration`) builds under the shared lock (`ci/job.sh integration-build`, the new
`zig build test:integration:build`, see 8), lets it go, then takes the **exclusive** lock for the
test alone (`ci/job.sh integration`, bounded by `CI_INTEGRATION_RUN_MINUTES`). A failed build skips the
test. A Markdown-only run (N68) exits before the job and takes no lock. The flow lives in `ci/cache.sh`
and `ci/ci_test.sh` tests it with stub jobs that report which lock they see and which fds are open.

**3. A turnstile against starvation, held only while waiting.** flock is not fair: shared steps arriving
one after another would keep an exclusive waiter out for ever. Every call first takes
`locks/turnstile.lock` (fd 11) exclusively, then `box.lock`, and lets the turnstile go as soon as it
holds `box.lock`, shared or exclusive. A waiting exclusive call therefore holds the turnstile only
while it waits, so no short job starts behind it, and not during the run. The order is always turnstile,
then box.

**4. No deadlock on the upgrade.** A step never waits for the turnstile or for an exclusive lock while it
holds `box.lock` shared: two integration steps would each hold shared and wait for the other. The
integration step releases the shared lock (build done) before the exclusive call. `ci_box_lock` refuses
a call made while the step holds the lock (`CI_BOX_HELD`: NRV-B1203).

**5. One budget per call, and it is the longest honest wait.** A call has one budget, `CI_BOX_WAIT`,
shared by its turnstile wait and its box wait (the second wait gets what the first left). The default
is derived from the jobs' limits (`ci_box_wait_default`): the longest a holder can legitimately keep
the box is a short job at its step limit (`CI_STEP_MINUTES`, 75) plus its root tests
(`CI_SCRIPTS_TEST_MINUTES`, 20) plus the exclusive test (`CI_INTEGRATION_RUN_MINUTES`, 20), each with
the kill-after (60 s), and 300 s more: 7380 s (123 minutes) with the defaults. It follows a raised
`CI_STEP_MINUTES`. A timeout means a holder outlived its own limits. The turnstile is therefore held
for at most one budget, 123 minutes at the very worst, and in practice until the running short jobs
end (about 25 minutes for the longest). A timeout fails the step with NRV-E1245, whose message names
who holds what; the test is never run without the lock. Only `flock` status 1 is a timeout; any other
status (for example fd 10 lost to a redirection) is NRV-B1204, a bug, never a timeout that blames
another holder. The knobs are validated by `ci_knobs_check` (NRV-E1208).

**6. The waits are accounted like other pre-job time.** They happen between `CI_STEP_START` and the job,
so `ci_job_seconds` and `ci_tail_seconds` count them as they count the `apt-get` before (NRV-W1207,
NRV-E1215). A short job waits in one call: at most 7380 s. An integration step waits in two (build,
then test): 2 x 7380 s = 246 minutes at the very worst, which is a bound, not an expectation: if the
waits really used that, the step's remaining time inside the repository's 360-minute limit could not
cover the build and test, and `ci_job_seconds` shortens or refuses the job (NRV-W1207, NRV-E1215)
rather than let the repository's timeout kill it. The long jobs wait for nothing, so a 330-minute
search is never shortened by this lock.

**7. The step closes fds 10 and 11 for the job's user,** as it closes 6 to 9 (`install_zig`, the root
tests and the job): a job must not be able to hold a lock for good. That is why the switch from shared
to exclusive is made by the root step between two job invocations, never inside the job. The
descriptors are numbered 10 and 11 because 3 to 9 are used by the other locks; they are opened with a
bare `exec`, never inside a `{ ...; } 2>/dev/null` group, which uses the first free descriptor from 10 up
to save stderr and would close them again.

**8. A build-only step in `build.zig` (owner-authorised; CLAUDE.md stop rule 2 waived for exactly this).**
`zig build test:integration:build` depends on the `test-integration` executable and on `nerva_keys_off`
and installs and runs nothing. After it, `zig build test:integration` recompiles nothing (checked: every
compile step reads "cached"), so the exclusive window is the run itself. Recorded in UPSTREAM.md.
`CI_INTEGRATION_RUN_MINUTES` defaults to 20: the run measured 10 minutes on a 4-core sandbox, so
twice that, and a hung one must not stall the box for an hour.

## Accepted: what the lock does not cover

- **Integration may still fail on timing while a long search or Jepsen runs beside it.** They are the
  jobs with a schedule and a slot of their own (the `fuzz-long` cron, set in Woodpecker's Settings,
  Cron, not in the repository; a hand-started `vopr-long`; a Jepsen run), and making integration wait
  hours for them, and every other job with it, is worse than a rare red. A red on timing during a long
  search is run again when it ends. Moving the long jobs off the box with #9's `tier` labels would
  remove this and is the follow-up.
- **The stall is real, and bounded.** While an integration step waits, no new short job starts (the
  turnstile): until the running short jobs end, in practice at most their limits (75 minutes), and
  123 minutes if one outlives its limit. Then every short job waits for the exclusive test: about 10
  minutes (607 s measured here), every push that runs integration, on every pipeline of the box, not
  only the pushing one. The stall of a short job is therefore the drain plus the runs of every
  integration step queued ahead of it: about 25 + k x 10 minutes for k concurrent pushes, which passes
  the 123-minute budget (and fails NRV-E1245 for the short job, with the holder named) at about
  k = 10. The old flaky red became a queue; that is the price of an honest timing test on a shared
  box, and the follow-up above (the `tier` labels) is how to take the box's other load away.
- **The simulator fleet** (`ops/sim-fleet`, `CPUWeight=idle`) takes no lock. It yields CPU time and
  disk but not cache or memory bandwidth. The 2.0 ms measurement does not say whether the fleet was
  running; it is not verified here.
- **Other steps' pre-job and tail work** (`apt-get`, a branch's seed copy, trash removal) runs beside
  the exclusive test, as it runs beside everything: only the jobs' runs are covered.
- **Jepsen's node containers** belong to the host's Docker daemon: a cancelled Jepsen step can leave
  them running. Jepsen takes no lock in any case.
- **Steps from a commit without this change** (an open branch not rebased) take no lock.
- The scheduling is not verified on the real box from here (see the pull request).

## Reason

The cheapest fix that keeps the test honest: the bound stays at one tick and the test stays the same,
while the short jobs, which finish in minutes, stop running beside it. The long jobs cannot be waited
for. The lock covers only runs, and the build-only step makes the exclusive window the test run alone,
not a compile, an `apt-get`, a cache copy or a trash walk.

## What it costs

- Integration waits for the short jobs already running, and they wait behind it while it waits and
  runs (see "Accepted").
- A vendored patch to `build.zig` (one step, additive; UPSTREAM.md).
- `ci/job.sh integration-build` (one line; open PR #9 changes other lines of the file).
- A red integration beside a long job, as above.
