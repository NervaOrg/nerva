---
id: O6
date: 2026-11-21
area: CI
amends: O4
---

# Branch pipelines run on on-demand Hetzner agents; main, cron, manual and Jepsen stay on the box

Pipelines queued behind one box (`check-packages` alone took about 42 minutes there). The box keeps
the shared caches that decision O4 guards, so a second kind of machine must not write them.

## Decision

**1. Two tiers.** Every `.woodpecker/*.yaml` carries `labels: tier: cloud` or `tier: box`. Cloud
agents (Hetzner CCX33 or CCX43, dedicated vCPUs, the box's location, created by the official
`woodpecker-ci/autoscaler` from a nightly snapshot) report `tier=cloud`; the box reports `tier=*`, so it
takes both. A cloud workflow runs only for a push to a branch other than `main` and `jepsen/**`, and for a
manual run without `NERVA_RUN`; a push to main, cron, `NERVA_RUN` manual runs, `vopr-main`, `fuzz-long`
and Jepsen are `tier: box`. Twin files (`F.yaml` cloud, `F-main.yaml` box) run the same job.

**2. The trust rule is O4's, unchanged.** A cloud workflow runs code that someone with push access to
the repository wrote (pull requests stay off, forks need approval: P147e), in a step that is not
privileged (O4), under the same seccomp profile. One rule: nothing runs on a cloud agent that could not
run on the box. What a cloud agent adds is disposal, not separation: a server takes one workflow at a time but keeps taking
them until it has been idle for `AS_IDLE`, so a job can leave something (any job can write every branch's
cache, O4) for the next workflow on the same server, as on the box. The server and its cache copy are deleted
afterwards, which bounds how long it lasts. (Whether the autoscaler 2.1.0 can end an agent after one workflow
was not verified, so this is not relied on.) A cloud agent never runs a main job, so it never writes
`main/`; the snapshot's copy of the main cache is a read-only seed (branch caches are seeded from it as on
the box). Its only secret is its own Woodpecker agent token. That token is in the server's user data, which
Hetzner's metadata service (169.254.169.254) serves to anything that can reach it: the snapshot has a
`DOCKER-USER` drop for that address, made at every boot (a unit), so job containers cannot read it, and
cloud-init deletes its own copies once the agent runs (user-data.txt, cloud-config.txt, the compose file and
the pickled datasource obj.pkl, which cloud-init rebuilds at the next boot). The agent starts only if the block
unit started and the rule is in place (one chained command); otherwise the server powers off, takes no job and
is reaped. Not covered: a step on the host network (the Trusted-network option), one that mounts `docker.sock`,
and one that mounts a host path (O4's Trusted volumes can reach `/var/lib/cloud`, where a copy may remain: the
same trust class as O4), and the metadata service itself, which keeps the data. The seed is `tools/` and `zig/p/` of main's cache only, copied while holding `main.lock` shared (a
prune or reset waits; main's steps also hold it shared and write `zig/p` without another lock, so the copy
can see a package half written). Zig trusts a package directory that is present in `zig/p` and does not hash
it again (`ci/cache.sh`'s seed copy says the same), so a half-written one in the seed would break builds until
the next night's snapshot. That Zig writes a package elsewhere and renames it into `zig/p`, so that the copy
sees all of it or none, was not verified).

**3. A hard cap and an idle timeout.** At most `AS_MAX` servers (default 4, never over 16; checked on every
start: NRV-E1238), one workflow per server, deleted when idle `AS_IDLE` (default 10 minutes). Servers carry
the label `nerva-ci-pool=cloud`; more than the cap is NRV-W1208. The snapshot builder's server and SSH key carry
`nerva-ci-pool=build`: it deletes them on any exit, by name if the create reply was lost, and the next build
sweeps any that are over 2 hours old (a SIGKILL or a reboot skips the exit). Builds run one at a time (a
lock), the snapshot may take 30 minutes, and a delete refused while the server is being snapshotted is retried.
The check for NRV-W1208 runs hourly (a timer) and after the nightly restart, and also warns of any cloud server
over 12 hours old: a leak at any count. The nightly restart ends the autoscaler without a goodbye (its container
is removed); it happens only after a successful build, so only when there is a new snapshot id. Whether 2.1.0
adopts the servers of its provider when it starts was not verified; the hourly check is the alarm if it does not.
`install` also try-restarts a running autoscaler, so that a lowered cap holds at once. It keeps two snapshots and never
prunes the one the autoscaler uses or the newest. The autoscaler counts only the pending workflows labelled
`tier=cloud` (`WOODPECKER_FILTER_LABELS`), so box-only work never creates a server. The service removes its
container before each start and when it stops, so a dead client does not leave an autoscaler running.

**4. Secrets are root's files.** `/etc/nerva-ci/hcloud.token` and `/etc/nerva-ci/woodpecker.token` are mode
0600 (NRV-E1237), mounted read-only into the autoscaler container and passed to `curl` on stdin; never in
the repository, argv, a unit or a log.

**5. `check-packages` is three shards** (by test class; `package_shards_N` in `ci/job.sh`), each class in
exactly one (NRV-E1244, tested), plus `check-packages-main`, which runs all of it on the box.

## Reason

Branch pipelines are the many and latency-sensitive ones, and they never write shared state. Dedicated
vCPUs keep timings stable. Reusing O4's rule adds no new trust decision: the one new thing to trust is
Hetzner's API token, confined to a project that holds only CI.

## Cost

Hourly Hetzner billing, bounded by the cap. GitHub's required check names change where a workflow was split
(`check-packages` no longer exists as one check; a push to main reports the `-main` workflows' names): the
owner updates the required-checks list, which this change did not. A main push has no cloud parallelism. The
snapshot uses Ubuntu's `docker.io`, not the box's Docker. The autoscaler's settings were not verified against
version 2.1.0's source: NRV-E1240 checks at install that its `--help` lists every environment variable
`run` passes, `WOODPECKER_FILTER_LABELS` among them (without it, box-only work would start cloud servers).
The gRPC address defaults to `CI_GRPC_HOST:443` (Caddy, TLS); any address that does not end in `:443` is refused (NRV-E1238).
