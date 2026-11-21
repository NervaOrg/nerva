---
id: O2c
date: 2026-11-21
area: "Milestone 3: positioned reads and the first views"
amends: N51
---

# The integration latency check asserts the fastest of 50 lookups, not the median

`test:integration` checked N51's fix by asserting that the median of 50 lookups was under one
tick (10 ms). On the Woodpecker box, which runs a pipeline's jobs side by side, the median reached
17.4 ms on a correct client (NervaOrg/nerva#11). The same commit measured 2.1 ms alone. With 8
busy loops on 4 cores, it measured 10.2 ms locally and failed the same way.

- **The check now asserts the fastest lookup.** N51's bug made every lookup wait out the tick, so
  even the fastest took at least 10 ms. On a loaded host, some lookups still return early.
  - Measured locally with 8 busy loops: fastest 1.9 ms, median 8.7 ms. Passes.
  - Mutation-tested with `IO.run_once` waiting out its duration: fastest 10.15 ms. Fails, as
    before.
- **Both values are printed,** so a slow median is still visible in the log.
- **Rejected:** a looser bound on the median, which weakens the check without removing the load
  dependence. Also rejected: a CI tier that runs integration alone, which leaves the
  check one that any busy host, a laptop included, can still break.

Cost: the check no longer notices a slower client whose fastest call still beats a tick. N51
named only the floor, and `nerva api` latency is not otherwise asserted.
