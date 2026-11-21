#!/usr/bin/env bash
# Fails with NRV-E1201 if this process cannot create an io_uring. Nerva's IO is io_uring; Docker's
# default seccomp profile refuses it (Docker 25 and later), and a replica then exits 70 with its
# reason in a log the tests discard: say so here instead. Steps are not privileged (decision O4):
# the host's Docker daemon carries a profile that allows it (ops/ci/docker/README.md).
# Statuses: the in-container python probe exits 0 (created), 3 (refused: NRV-E1201) or anything else
# (broken: NRV-E1223); this script itself exits 0 or 1. The host probe, ops/ci/io_uring_probe.sh,
# has its own convention, as its header says: there 1 is refused and 3 is broken.
# `--pretend-refused` fails as if the kernel had said EPERM (the table test).
set -euo pipefail
. "$(dirname "$0")/lib.sh"

rc=0
msg=$(python3 - "${1:-}" 2>&1 <<'EOF'
import ctypes, errno, os, sys
if sys.argv[1] == "--pretend-refused":
    fd, err = -1, errno.EPERM
else:
    libc = ctypes.CDLL(None, use_errno=True)
    params = ctypes.create_string_buffer(120)  # struct io_uring_params
    fd = libc.syscall(425, 1, params)  # io_uring_setup, the same number on x86_64 and aarch64
    err = ctypes.get_errno()
if fd < 0:
    print(os.strerror(err))
    sys.exit(3)  # 3, not 1: an uncaught exception exits 1
os.close(fd)
EOF
) || rc=$?
# Exit 3 is the probe's own "refused"; any other status (a traceback is 1, 127 for no python3) is a
# broken probe, which says nothing about io_uring.
if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then
    ci_error "NRV-E1223: the io_uring probe itself failed ($(tail -n 1 <<<"$msg")): install python3 in this image or fix what it names; this is not a refusal by the kernel"
    exit 1
fi
if [ "$rc" -eq 3 ]; then
    ci_error "NRV-E1201: io_uring is refused here ($msg): the host's Docker daemon needs the seccomp profile ops/ci/docker/seccomp-io_uring.json (run ops/ci/woodpecker-bootstrap.sh again), or the host has kernel.io_uring_disabled set"
    exit 1
fi
