#!/usr/bin/env bash
# Fails with NRV-E1201 if this process cannot create an io_uring. Nerva's IO is io_uring; Docker's
# default seccomp profile refuses it (Docker 25 and later), and a replica then exits 70 with its
# reason in a log the tests discard: say so here instead. Steps are not privileged (decision O4):
# the host's Docker daemon carries a profile that allows it (ops/ci/docker/README.md).
# `--pretend-refused` fails as if the kernel had said EPERM (the table test).
set -euo pipefail
. "$(dirname "$0")/lib.sh"

msg=$(python3 - "${1:-}" <<'EOF'
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
    sys.exit(1)
os.close(fd)
EOF
) || {
    ci_error "NRV-E1201: io_uring is refused here ($msg): the host's Docker daemon needs the seccomp profile ops/ci/docker/seccomp-io_uring.json (run ops/ci/woodpecker-bootstrap.sh again), or the host has kernel.io_uring_disabled set"
    exit 1
}
