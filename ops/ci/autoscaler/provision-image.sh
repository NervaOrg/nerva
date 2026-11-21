#!/usr/bin/env bash
# Runs as root ON the temporary Hetzner server that nerva-autoscaler-image.sh builds the snapshot on
# (decision O6), from /root/ci/autoscaler/, after the image script has copied ops/ci/ and the box's
# main cache (the warm-cache seed) to it. Never run it on the CI box: it removes the machine's SSH
# host keys and cloud-init state, so that the next server booted from the snapshot is a new machine.
#
# Makes the snapshot: Docker with the io_uring seccomp profile (ops/ci/docker/, decision O4), the
# pinned CI and agent images pulled, the pinned Zig toolchain archive verified by sha256 (lib.sh), the
# cache directories of nerva-woodpecker.sh host, a firewall rule against the metadata service, and the seed under /var/cache/nerva-ci/main, which
# no job but a push to main may write (and a cloud agent never runs one: decision O6).
# shellcheck disable=SC2154,SC2034 # etc, tool and the pins come from lib.sh (not followed: no -x)
set -euo pipefail

tool=provision-image
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

[ "$(id -u)" = 0 ] || fail "NRV-E1242: the image was not built: provision-image.sh must run as root, on the temporary server"
[ "${NERVA_AS_ON_BUILD_SERVER:-}" = yes ] || fail "NRV-E1242: the image was not built: provision-image.sh only runs on the temporary build server (it is started by nerva-autoscaler-image.sh)"
seed=/var/cache/nerva-ci/main
[ -d "$seed" ] && [ -n "$(ls -A "$seed")" ] || fail "NRV-E1242: the image was not built: the warm-cache seed $seed was not copied to the build server"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq docker.io docker-compose-v2 jq curl xz-utils fuse3 acl iptables > /dev/null

install -d -m 0755 /etc/docker
install -m 0644 "$here/../docker/seccomp-io_uring.json" /etc/docker/seccomp-io_uring.json
jq -n '{"seccomp-profile": "/etc/docker/seccomp-io_uring.json"}' > /etc/docker/daemon.json
systemctl enable docker > /dev/null
systemctl restart docker

# Containers (the jobs) must not reach Hetzner's metadata service, which serves this server's user data
# with the agent token (cloud-init.tmpl.yaml): a DOCKER-USER drop, made again at every boot and every
# Docker restart by a unit. It is checked here, so a snapshot without the rule is never made.
install -m 0644 "$here/nerva-ci-metadata-block.service" /etc/systemd/system/nerva-ci-metadata-block.service
systemctl daemon-reload
systemctl enable nerva-ci-metadata-block.service > /dev/null
systemctl restart nerva-ci-metadata-block.service
iptables -w -C DOCKER-USER -d 169.254.169.254 -j DROP || fail "NRV-E1242: the image was not built: the DOCKER-USER rule that blocks 169.254.169.254 is not in place"

# The pinned CI image is pulled and the io_uring probe runs in it: a snapshot whose Docker refuses
# io_uring is never made.
bash "$here/../io_uring_probe.sh" || fail "NRV-E1242: the image was not built: a container on the build server cannot create an io_uring (decision O4)"
docker pull -q "$AGENT_IMAGE" > /dev/null || fail "NRV-E1242: the image was not built: could not pull $AGENT_IMAGE"
docker image inspect "$CI_IMAGE" > /dev/null || fail "NRV-E1242: the image was not built: $CI_IMAGE is not on the build server"

# The pinned Zig toolchain, verified (ci/install_zig.sh finds it by the same sha256).
install -d -m 0755 /opt/nerva-ci
zig_tar=/opt/nerva-ci/zig-x86_64-linux-$ZIG_VERSION.tar.xz
curl -fsSL -m 600 -o "$zig_tar" "$ZIG_URL" || fail "NRV-E1242: the image was not built: could not download $ZIG_URL"
got=$(sha256sum "$zig_tar" | cut -d ' ' -f 1)
[ "$got" = "$ZIG_SHA256" ] || { rm -f "$zig_tar"; fail "NRV-E1242: the image was not built: the Zig archive has sha256 $got, not the pinned $ZIG_SHA256"; }

# The cache directories (main is root's, 0755; branches and locks are made by the first job). The build
# server runs no agent: --no-agent skips the check for the agent container (NRV-E1216).
bash "$here/../nerva-woodpecker.sh" host --no-agent || fail "NRV-E1242: the image was not built: nerva-woodpecker.sh host failed on the build server"

# Make the next boot a new machine: no SSH host keys or login keys, no cloud-init state, no logs.
apt-get clean
rm -rf /root/ci /root/.ssh/authorized_keys /etc/ssh/ssh_host_* /var/lib/apt/lists/*
cloud-init clean --logs
truncate -s 0 /etc/machine-id
fstrim -a || true
echo "provision-image: OK"
