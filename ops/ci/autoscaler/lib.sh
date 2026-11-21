#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154 # the pins are read by the scripts that source this; `tool` is theirs
# Shared by nerva-autoscaler.sh and nerva-autoscaler-image.sh (decision O6). Sourced, never run.
# Needs the caller to set `tool` (its name, for messages). Errors are `FAIL NRV-E12xx: ...` (docs/ERRORS.md).

# The pins. ci/autoscaler_test.sh checks them against zig/download.sh, .woodpecker/ and the bootstrap.
AUTOSCALER_IMAGE=docker.io/woodpeckerci/autoscaler:2.1.0@sha256:b4eb1c3edeebe66cb620d89309b7a2d1428eaf2a3ee5e9cdca7564da64139bc3
AGENT_IMAGE=docker.io/woodpeckerci/woodpecker-agent:v3.20.1@sha256:a7d7299a13add0b3936fa0ac9ed23507fe283a7fc7d9596c4289d7e8206541eb
CI_IMAGE=docker.io/library/ubuntu:24.04@sha256:73b999393d07f2bf65a40373778a44dc9a6d54ad7718d29247d8ff9413c4d6a8
ZIG_VERSION=0.14.1
ZIG_URL=https://ziglang.org/download/0.14.1/zig-x86_64-linux-0.14.1.tar.xz
ZIG_SHA256=24aeeec8af16c381934a6cd7d95c807a8cb2cf7df9fa40d359aa884195c4716c
POOL_LABEL=nerva-ci-pool # the Hetzner label on every server and snapshot this setup makes
CAP_MAX=16               # no setting can raise the server cap past this

etc="${NERVA_CI_ETC:-/etc/nerva-ci}"
api_url="${NERVA_HCLOUD_API:-https://api.hetzner.cloud/v1}"

fail() { echo "$tool: FAIL $*" >&2; exit 1; }
say() { echo "$tool: $*"; }

# secret_file PATH WHAT: PATH is a regular file, root's, mode 0600 and not empty (NRV-E1237).
secret_file() {
    local mode owner
    { [ -f "$1" ] && [ ! -L "$1" ]; } || fail "NRV-E1237: $2 ($1) is missing or not a regular file: create it, owned by root, mode 0600, with the secret on one line (ops/ci/README.md, \"Cloud agents\")"
    mode=$(stat -c %a "$1")
    owner=$(stat -c %u "$1")
    { [ "$mode" = 600 ] && [ "$owner" = "${NERVA_CI_ROOT_UID:-0}" ]; } || fail "NRV-E1237: $2 ($1) is mode $mode, owner $owner: it must be root's and mode 0600 (chown root:root, chmod 600)"
    [ -s "$1" ] || fail "NRV-E1237: $2 ($1) is empty"
}

# conf_load: reads $etc/autoscaler.conf and checks every setting here and nowhere else (NRV-E1238).
conf_load() {
    local v
    [ -f "$etc/autoscaler.conf" ] || fail "NRV-E1238: $etc/autoscaler.conf is missing: run nerva-autoscaler.sh install first"
    # shellcheck disable=SC1091
    . "$etc/autoscaler.conf"
    for v in AS_SERVER AS_GRPC AS_LOCATION AS_SERVER_TYPE AS_MAX AS_IDLE AS_TIER; do
        [ -n "${!v:-}" ] || fail "NRV-E1238: $v is not set in $etc/autoscaler.conf"
    done
    [[ "$AS_SERVER" =~ ^https://[A-Za-z0-9.-]+$ ]] || fail "NRV-E1238: AS_SERVER='$AS_SERVER' is not https://HOST"
    [[ "$AS_GRPC" =~ ^[A-Za-z0-9.-]+:[0-9]+$ ]] || fail "NRV-E1238: AS_GRPC='$AS_GRPC' is not HOST:PORT"
    [[ "$AS_LOCATION" =~ ^[a-z]{3}[0-9]$ ]] || fail "NRV-E1238: AS_LOCATION='$AS_LOCATION' is not a Hetzner location such as fsn1 (use the box's)"
    [[ "$AS_SERVER_TYPE" =~ ^ccx(33|43)$ ]] || fail "NRV-E1238: AS_SERVER_TYPE='$AS_SERVER_TYPE' is not ccx33 or ccx43 (dedicated vCPUs: shared ones make timings noisy)"
    { [[ "$AS_MAX" =~ ^[0-9]+$ ]] && [ "$AS_MAX" -ge 1 ] && [ "$AS_MAX" -le "$CAP_MAX" ]; } || fail "NRV-E1238: AS_MAX='$AS_MAX' is not a number from 1 to $CAP_MAX (the hard cap on cloud servers)"
    { [[ "$AS_IDLE" =~ ^[0-9]+m$ ]] && [ "${AS_IDLE%m}" -ge 1 ] && [ "${AS_IDLE%m}" -le 60 ]; } || fail "NRV-E1238: AS_IDLE='$AS_IDLE' is not minutes from 1m to 60m"
    [ "$AS_TIER" = cloud ] || fail "NRV-E1238: AS_TIER='$AS_TIER' must be cloud (the label cloud agents carry, decision O6)"
}

# hcloud METHOD PATH [JSON]: one Hetzner Cloud API call. The token is read from its file and handed to
# curl as a config on stdin, so it is never in argv, the environment or a log. Prints the body; a
# failure is NRV-E1241.
hcloud() {
    local method=$1 path=$2 body="${3:-}" out code
    local -a args=(-sS -m 60 -K - -X "$method" -w '\n%{http_code}' -H 'Content-Type: application/json')
    [ -z "$body" ] || args+=(--data-binary "$body")
    out=$(printf 'header = "Authorization: Bearer %s"\n' "$(cat "$etc/hcloud.token")" | curl "${args[@]}" "$api_url$path") || fail "NRV-E1241: the Hetzner API ($api_url) could not be reached: $method $path"
    code=${out##*$'\n'}
    out=${out%$'\n'*}
    [[ "$code" =~ ^2[0-9][0-9]$ ]] || fail "NRV-E1241: Hetzner refused $method $path with HTTP $code: $(printf '%s' "$out" | jq -r '.error.message // empty' 2>/dev/null | head -c 200)"
    printf '%s\n' "$out"
}
