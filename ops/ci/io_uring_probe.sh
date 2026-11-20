#!/usr/bin/env bash
# Can a container on this host's Docker daemon create an io_uring? Used by woodpecker-bootstrap.sh
# (after it restarts Docker) and nerva-woodpecker.sh host, and tested by ci/ci_test.sh.
#
#   bash io_uring_probe.sh          pull the pinned ubuntu image, run the probe in a throwaway container
#   bash io_uring_probe.sh local    run the probe on this host, with no container (the test)
#
# Exit 0: an io_uring was created. Exit 1: refused (NRV-E1201), with the kernel's reason. Exit 2:
# the image could not be pulled (NRV-E1211). Exit 3: the probe itself failed, so nothing is known
# about the profile (NRV-E1212). One line on stderr says which, and why. The probe's perl exits 0
# or 1 and never anything else: a perl that dies exits 255, which is reported as a broken probe
# (exit 3), not as a refusal.
set -u

image=docker.io/library/ubuntu:24.04@sha256:73b999393d07f2bf65a40373778a44dc9a6d54ad7718d29247d8ff9413c4d6a8
# io_uring_setup is 425 on x86_64 and aarch64; struct io_uring_params is 120 bytes. The buffer is
# a variable because perl's syscall refuses a constant ("Modification of a read-only value").
probe='my $p = "\0" x 120; my $r = syscall(425, 1, $p); if ($r < 0) { print STDERR "$!\n"; exit 1 } exit 0'

if [ "${1:-}" = local ]; then
    exec perl -e "$probe"
fi

if ! out=$(docker pull --quiet "$image" 2>&1); then
    last=$(tail -n 1 <<<"$out")
    if grep -q "Cannot connect to the Docker daemon" <<<"$out"; then
        hint="the Docker daemon may be down (systemctl status docker), or the box's network or Docker Hub's rate limit (docker login) may be at fault"
    else
        hint="check the box's network and Docker Hub's rate limit (docker login); if the message says the daemon is not reachable, it may be down (systemctl status docker)"
    fi
    echo "NRV-E1211: could not pull $image ($last): $hint, then run this again" >&2
    exit 2
fi
out=$(docker run --rm "$image" perl -e "$probe" 2>&1)
case $? in
    0) exit 0 ;;
    1) echo "NRV-E1201: a throwaway container cannot create an io_uring ($(tail -n 1 <<<"$out")): the daemon does not run the profile ops/ci/docker/seccomp-io_uring.json (run woodpecker-bootstrap.sh again, from the directory that holds docker/seccomp-io_uring.json), or the host has kernel.io_uring_disabled set" >&2
        exit 1 ;;
    *) echo "NRV-E1212: the io_uring probe itself failed, so the daemon's profile is unknown ($(tail -n 1 <<<"$out")): read the reason, then run \`docker run --rm $image perl -e 1\` by hand" >&2
        exit 3 ;;
esac
