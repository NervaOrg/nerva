# Docker's seccomp profile for Nerva's CI steps

`seccomp-io_uring.json` is Docker's default seccomp profile plus one unconditional rule that allows
`io_uring_setup`, `io_uring_enter` and `io_uring_register`. Nerva's IO is io_uring, and Docker's
default profile has refused it since Docker 25 (moby#46762). The profile replaces `privileged: true`
on the Woodpecker steps (decision O4): a step keeps Docker's default capabilities and every other
default restriction, and loses nothing but the io_uring block.

- **Source:** `profiles/seccomp/default.json` of moby/moby at tag `v28.3.3`, sha256
  `01536f1d1df938ae611eba20d6349e0de7a99b6ecdee1549427a0b01b8301e28` (13063 bytes), fetched
  2026-11-20. It is the newest tag whose `profiles/seccomp/default.json` could be fetched: from
  Docker 28.5 and 29 the profile is generated in code and the file is no longer at that path.
  Docker 29 (what Ubuntu 24.04's `docker.io` installs today) therefore runs under a profile
  that is a few releases older than its own default. Syscalls added since 28.3.3 stay refused
  (the bootstrap prints Docker's version when it installs the profile). If a job fails with
  `Operation not permitted` on a syscall newer than 28.3.3, add it to the rule here, in the same
  pull request as the fix.
- **Change from the source:** the last entry of `syscalls` (appended with
  `jq --tab '.syscalls += [{"names":["io_uring_setup","io_uring_enter","io_uring_register"],"action":"SCMP_ACT_ALLOW"}]'`).
  The diff against the source file is that entry alone.
- **Installed by** `ops/ci/woodpecker-bootstrap.sh`: it copies this file to
  `/etc/docker/seccomp-io_uring.json` and sets `"seccomp-profile"` in `/etc/docker/daemon.json`
  (merging what is there), then restarts Docker. A daemon-wide profile applies to every
  container the daemon creates without its own `--security-opt seccomp=...`, which includes the
  Woodpecker steps.
- **Not covered:** containers started with `--privileged` (Jepsen's five node containers) have no
  seccomp profile at all, as before.
