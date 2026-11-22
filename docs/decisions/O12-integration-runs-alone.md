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
did not add up. The third held the whole of `zig build test:integration` (about 10 minutes, scenarios and
all) exclusive, behind a build-only step added to `build.zig`; the owner turned that down (a vendored file
for a scheduling problem, and a 10-minute stall per push). This is the fourth: only the scenario that
carries the timing bound runs exclusive, and nothing vendored changes. O12 was not merged before.

## Decision

**1. Two kinds of job.** The *long* jobs, `fuzz-long`, `vopr-long` and `jepsen` (`ci/woodpecker_step.sh`,
`box=none`), take no lock and never wait for one. Every other job is *short* (75 minutes at most: its own
step limit; about 25 minutes for the longest, `check-packages`).

**2. A host-wide reader/writer lock around the run alone.** `ci_box_lock` and `ci_box_unlock`
(`ci/cache.sh`) take and release `locks/box.lock` (fd 10) around the job's run and nothing else: not
the `apt-get`, the seed copy, `install_zig`, nor the tail (`ci_step_finish`). A short job holds it
**shared**, so short jobs run side by side as before (`ci_step_job_in_box`). The `integration` job
(`ci_step_integration`) runs every scenario but the timed one under the shared lock
(`ci/job.sh integration untimed`: it compiles everything, and it is the part that takes the minutes),
lets it go, then takes the **exclusive** lock for the timed scenario alone (`ci/job.sh integration
timed`, bounded by `CI_INTEGRATION_RUN_MINUTES`, see 8). A failed untimed run skips the timed one. A Markdown-only run (N68) exits before the job and takes no lock. The flow lives in `ci/cache.sh`
and `ci/ci_test.sh` tests it with stub jobs that report which lock they see and which fds are open.

**3. A turnstile against starvation, held only while waiting.** flock is not fair: shared steps arriving
one after another would keep an exclusive waiter out for ever. Every call first takes
`locks/turnstile.lock` (fd 11) exclusively, then `box.lock`, and lets the turnstile go as soon as it
holds `box.lock`, shared or exclusive. A waiting exclusive call therefore holds the turnstile only
while it waits, so no short job starts behind it, and not during the run. The order is always turnstile,
then box.

**4. No deadlock on the upgrade.** A step never waits for the turnstile or for an exclusive lock while it
holds `box.lock` shared: two integration steps would each hold shared and wait for the other. The
integration step releases the shared lock (untimed run done) before the exclusive call. `ci_box_lock` refuses
a call made while the step holds the lock (`CI_BOX_HELD`: NRV-B1203).

**5. One budget per call, and it is the longest honest wait.** A call has one budget, `CI_BOX_WAIT`,
shared by its turnstile wait and its box wait (the second wait gets what the first left). The default
is built from the jobs' limits (`ci_box_wait_default`): the longest *one* holder keeps the box is a
short job at its step limit (75 minutes) plus its root tests (20) plus the exclusive run
(`CI_INTEGRATION_RUN_MINUTES`, 5), each with the kill-after (60 s), and 300 s more: 6480 s (108
minutes) with the defaults. The holders may belong to other pipelines with other knobs, so the
waiter's own `CI_STEP_MINUTES` and `CI_SCRIPTS_TEST_MINUTES` can only raise those limits, never
lower them below these fixed defaults (a floor; a waiter dispatched with `CI_STEP_MINUTES=20` still
waits 6480 s). **The budget is the longest single hold, not a bound on the queue.** One call's turnstile
hold is at most one budget, but a call can queue behind several integration steps, and each can cost a
full drain (see "Accepted": a short job that queues behind an integration step runs for up to its
limit before the next integration step can start its own wait). So NRV-E1245 means a holder outlived
its limit *or* several integration steps are queued ahead, with every holder inside its limits. A
timeout fails the step with NRV-E1245, whose message names who holds what; the test is never run
without the lock. Only `flock` status 1 is a timeout; any other
status (for example fd 10 lost to a redirection) is NRV-B1204, a bug, never a timeout that blames
another holder. The knobs are validated by `ci_knobs_check` (NRV-E1208).

**6. The waits are accounted like other pre-job time.** They happen between `CI_STEP_START` and the job,
so `ci_job_seconds` and `ci_tail_seconds` count them as they count the `apt-get` before (NRV-W1207,
NRV-E1215). A short job waits in one call: one budget, 6480 s by default (the budget bounds the call, not the queue it waits in). An integration step waits in two (untimed,
then timed): 2 x 6480 s = 216 minutes at the very worst, which is a bound, not an expectation: if the
waits really used that, the step's remaining time inside the repository's 360-minute limit could not
cover the two runs, and `ci_job_seconds` shortens or refuses the job (NRV-W1207, NRV-E1215)
rather than let the repository's timeout kill it. The long jobs wait for nothing, so a 330-minute
search is never shortened by this lock.

**7. The step closes fds 10 and 11 for the job's user,** as it closes 6 to 9 (`install_zig`, the root
tests and the job): a job must not be able to hold a lock for good. That is why the switch from shared
to exclusive is made by the root step between two job invocations, never inside the job. The
descriptors are numbered 10 and 11 because 3 to 9 are used by the other locks; they are opened with a
bare `exec`, never inside a `{ ...; } 2>/dev/null` group, which uses the first free descriptor from 10 up
to save stderr and would close them again.

**8. The test binary runs a chosen subset of its scenarios; nothing vendored changes.**
`src/integration_tests.zig` (Nerva's own: UPSTREAM.md lists TigerBeetle's as dropped) reads
`NERVA_INTEGRATION_SCENARIOS` in `main` (`zig build test:integration` passes the build's environment on to
its run step, which is never cached: it has side effects). The value is a comma-separated list of scenario
names (`cluster`, `peer_auth`, `latency`) or of the groups `untimed` and `timed`; **unset, every scenario
runs, exactly as before** (GitHub Actions, CLAUDE.md's command, a run by hand). A scenario is *timed* when
it asserts a wall-clock bound; `Scenario.timed` is an exhaustive `switch`, so a new scenario must say, and
CI's `untimed` picks up every scenario not marked: none is silently left out of CI. Anything else, an empty
value or an empty entry included, fails with NRV-E1246 and runs nothing: a typo can never be a green run
that executed no scenario. The selection is `src/nerva/integration_scenarios.zig`, kept apart so that
`test:unit` reaches its tests (the executable's own `test` blocks have no root; `src/unit_tests.zig` gains
its one line from its own quine, a regeneration, not a golden value of anything else). Alternatives
rejected: a build-only step in `build.zig` (the third version: a vendored patch, and it left the whole
10-minute run exclusive), command-line arguments (`build.zig` does not pass any on), running the cached
binary by its path (the path is a hash).

**The latency check is its own small scenario.** The 50 lookups were in the middle of `scenario_cluster`,
which does much more (a crash, a restart, the change feed, eviction by 64 clients). They moved to
`scenario_latency`: a cluster start, one put, one lookup (the row is there) and the 50 timed lookups, on
a cluster of its own. What it asserts is the same (median of 50 lookups under one tick); what
`scenario_cluster` asserts is the same minus those lookups, which asserted nothing else. The one change
in coverage: the timed lookups no longer run on a cluster that has already committed, raced and served a
change feed, but on one that has committed one row; the code path of a lookup is the same, and the median
measured 1.4 and 1.5 ms (before: 2.0 to 2.3 ms alone), with one client instead of two.

**The Python tests that follow stay out of the exclusive run.** `zig build test:integration` also runs
`tests/errors/commands.py` and `tests/recover/recover.py` after the executable (build graph: they depend on
it); they take about 5 minutes and measure nothing against the clock. With `NERVA_INTEGRATION_SCENARIOS`
selects no untimed scenario (every entry is `timed` or a scenario `Scenario.timed` marks: `timed`,
`latency`, a list of them) each prints a one-line skip and exits 0, so the exclusive run is the timed
scenario alone (measured: 7 s in all, `zig build` start-up included, with everything compiled by the
untimed run); the untimed run, a run with the variable unset, `cluster` or any list holding an untimed
entry run them as before. `ci/ci_test.sh` pins both sides: it runs each script with a value of each
kind and fails if the skip fires on unset, `untimed`, `cluster` or a mixed list, or does not fire on
`timed`, `latency` or a list of them, and it checks that each script's `TIMED_SCENARIOS` equals the names
`Scenario.timed` marks. Not chosen: one explicit flag from the Zig side (`build.zig` passes nothing on and
is vendored). The cost: those two scripts know the timed names, kept in step by that check.
The value is bounded too (`value_max`, 256 bytes; longer is NRV-E1246, tested at the bound and one past
it), and an unreadable value or a refusal prints one coded line, never a raw error name.
`CI_INTEGRATION_RUN_MINUTES` defaults to 5: forty times the measured run, and a
hung cluster must not stall the box for more.

## Accepted: what the lock does not cover

- **Integration may still fail on timing while a long search or Jepsen runs beside it.** They are the
  jobs with a schedule and a slot of their own (the `fuzz-long` cron, set in Woodpecker's Settings,
  Cron, not in the repository; a hand-started `vopr-long`; a Jepsen run), and making integration wait
  hours for them, and every other job with it, is worse than a rare red. A red on timing during a long
  search is run again when it ends. Moving the long jobs off the box with #9's `tier` labels would
  remove this and is the follow-up.
- **The stall is real.** While an integration step waits, no new short job starts (the
  turnstile): until the running short jobs end, which is the longest of them, about 25 minutes if
  `check-packages` has just started, less for the others, and at most their limits (75 minutes; 108
  minutes if one outlives its limit). Then the exclusive run takes seconds (7 s measured here). **With
  more than one integration step the drain repeats.** The turnstile is let go when an integration step
  holds the box, so a short job queued behind it takes the turnstile, runs for up to its limit, and
  a second integration step that arrived during the first one's run queues behind that short job and
  must wait for it: a second full drain. Every short job behind the second step waits for that drain
  too. Each integration step queued ahead can therefore cost a whole drain (about 25 minutes with
  `check-packages`, up to 75), not about 10 s. With two or three concurrent pushes and long short
  jobs, a short job can pass the 108-minute budget with nothing stuck, and NRV-E1245 then fires although
  every holder is inside its limits (`ci/cache.sh` and ERRORS.md say so in the message and the entry: start
  it again). The code keeps this: a budget that covered the queue would have to scale with the number of
  pushes, and a red on a loaded box that is run again is the cheaper failure; a fair queue (a ticket
  order) is the fix if it shows up, together with the `tier` labels. The previous version held every
  push's short jobs for the drain plus about 10 minutes; this one holds them for the drain plus
  seconds, once per integration step ahead.
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
for. The lock covers only runs, and only the timed scenario runs exclusive: the exclusive window is a
cluster start and 50 lookups (seconds), not the 10 minutes of the whole suite, a compile, an `apt-get`,
a cache copy or a trash walk. The scheduling problem is solved where it is (CI's order of runs) and in
Nerva's own test file, not in a vendored one.

## What it costs

- Integration waits for the short jobs already running, and they wait behind it while it waits and
  runs (see "Accepted"); the run itself is seconds, but each integration step queued ahead of a short
  job can cost it a drain, so a short job can fail NRV-E1245 with no holder over its limit.
- `src/integration_tests.zig` and its selection module are a little larger (one new scenario, one
  environment variable, one code, NRV-E1246), and two Python tests know the timed names.
- The latency check no longer runs on a cluster that has done everything else first (see 8).
- `ci/job.sh integration` takes an argument (open PR #9 changes other lines of the file).
- A red integration beside a long job, as above.
