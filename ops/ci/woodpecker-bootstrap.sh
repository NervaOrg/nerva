#!/usr/bin/env bash
# Woodpecker CI on one Ubuntu 24.04 box: Docker, the Woodpecker server, one agent and Caddy (TLS
# from Let's Encrypt), for any project on GitHub or on a Forgejo. Run it as root on the box:
#
# It runs on the box, from ~, after `scp -r ops/ci root@BOX:` (the whole directory, which lands
# at ~/ci/ on the box; the script needs docker/seccomp-io_uring.json and io_uring_probe.sh beside it):
#
#   bash ci/woodpecker-bootstrap.sh            the server and an agent on this box
#   bash ci/woodpecker-bootstrap.sh agent      only an agent, on another box, for an existing server
#
# The box gets Docker's io_uring seccomp profile, which Nerva's CI needs (decision O4). For a
# project that does not need io_uring: CI_SECCOMP=no bash ci/woodpecker-bootstrap.sh (Docker then
# keeps its default profile, and Nerva's steps fail NRV-E1201).
#
# It asks for what it does not have yet and keeps the answers in /etc/woodpecker/ (ci.env, not
# secret; the secret files beside it are 0640 and never put on a command line). Safe to run again:
# it asks only for what is missing and changes only what differs. Its last line is
# `woodpecker-bootstrap: OK ...` or `woodpecker-bootstrap: FAIL <why>`.
set -euo pipefail

woodpecker_version=v3.20.1
caddy_version=2.10.2
etc=/etc/woodpecker
opt=/opt/woodpecker
mode="${1:-server}"

fail() { echo "woodpecker-bootstrap: FAIL $*"; exit 1; }
step() { echo "woodpecker-bootstrap: $*"; }
tmpfiles=()
trap 'rm -f "${tmpfiles[@]}"' EXIT

ask() { # ask VAR PROMPT [DEFAULT]: reads from the terminal, never from a pipe.
    [ -r /dev/tty ] || fail "$2 is needed and there is no terminal to ask on (ssh -t)"
    local answer
    read -r -p "$2${3:+ [$3]}: " answer </dev/tty
    printf -v "$1" '%s' "${answer:-${3:-}}"
}
ask_secret() { # ask_secret FILE PROMPT: writes the answer to FILE (0600), never echoes it.
    [ -r /dev/tty ] || fail "$2 is needed and there is no terminal to ask on (ssh -t)"
    local answer
    read -r -s -p "$2 (hidden): " answer </dev/tty
    echo
    [ -n "$answer" ] || fail "$2 was empty"
    (umask 077; printf '%s' "$answer" > "$1")
}
setting() { # setting NAME VALUE: writes NAME=VALUE into ci.env, replacing an earlier line.
    grep -v "^$1=" "$etc/ci.env" > "$etc/ci.env.new" || true
    printf '%s=%s\n' "$1" "$2" >> "$etc/ci.env.new"
    mv "$etc/ci.env.new" "$etc/ci.env"
}
valid() { # valid NAME REGEX: the setting must match, so it is safe in YAML, sed and URLs.
    [[ "${!1:-}" =~ ^$2$ ]] || fail "$1='${!1:-}' in $etc/ci.env is not valid"
}

# --- Preflight -----------------------------------------------------------------------------------
[ "$(id -u)" = 0 ] || fail "run as root"
case "$mode" in server | agent) ;; *) fail "unknown mode '$mode' (server or agent)" ;; esac
. /etc/os-release
[ "${ID:-}" = ubuntu ] && [ "${VERSION_ID:-}" = 24.04 ] ||
    fail "this script is written for Ubuntu 24.04, found ${PRETTY_NAME:-unknown}"
# Everything the profile step needs is checked here, before the script changes anything.
here="$(dirname "$(readlink -f "$0")")"
seccomp_src="$here/docker/seccomp-io_uring.json"
probe="$here/io_uring_probe.sh"
seccomp="${CI_SECCOMP:-yes}"
case "$seccomp" in yes | no) ;; *) fail "CI_SECCOMP='$seccomp' is not yes or no" ;; esac
if [ "$seccomp" = yes ]; then
    for f in "$seccomp_src" "$probe"; do
        [ -f "$f" ] ||
            fail "NRV-E1213: $f is missing: run this from a copy of the whole ops/ci/ directory (scp -r ops/ci root@BOX:, then bash ci/woodpecker-bootstrap.sh), or CI_SECCOMP=no for a project that does not need io_uring"
    done
fi
modprobe kvm_amd 2>/dev/null || modprobe kvm_intel 2>/dev/null || true
if ! command -v jq >/dev/null || ! command -v curl >/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get update -q
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q curl jq
fi

# --- Settings ------------------------------------------------------------------------------------
install -d -m 0711 "$etc"
touch "$etc/ci.env"
chmod 0644 "$etc/ci.env"
set -a; . "$etc/ci.env"; set +a
kvm_default=no
[ -c /dev/kvm ] && kvm_default=yes
if [ -z "${CI_AGENT_NAME:-}" ]; then
    ask CI_AGENT_NAME "This agent's name" "$(hostname -s)"
    setting CI_AGENT_NAME "$CI_AGENT_NAME"
fi
if [ -z "${CI_MAX_WORKFLOWS:-}" ]; then
    n=$(( $(nproc) / 4 )); [ "$n" -ge 1 ] || n=1
    ask CI_MAX_WORKFLOWS "Workflows this agent runs at once" "$n"
    setting CI_MAX_WORKFLOWS "$CI_MAX_WORKFLOWS"
fi
if [ -z "${CI_KVM:-}" ]; then
    ask CI_KVM "Offer /dev/kvm to pipelines (label kvm=true)? yes or no" "$kvm_default"
    setting CI_KVM "$CI_KVM"
fi
valid CI_AGENT_NAME '[A-Za-z0-9._-]+'
valid CI_MAX_WORKFLOWS '[1-9][0-9]*'
valid CI_KVM 'yes|no'
if [ "$CI_KVM" = yes ] && [ ! -c /dev/kvm ]; then
    fail "CI_KVM=yes but /dev/kvm is missing (a cloud VM has none; use a dedicated server, or \
turn on SVM/VT-x in the BIOS)"
fi

if [ "$mode" = server ]; then
    if [ -z "${CI_HOST:-}" ]; then
        ask CI_HOST "DNS name of this box (e.g. ci.example.org)"
        setting CI_HOST "$CI_HOST"
    fi
    if [ -z "${CI_FORGE:-}" ]; then
        ask CI_FORGE "Where the code lives: github or forgejo" github
        setting CI_FORGE "$CI_FORGE"
    fi
    valid CI_FORGE 'github|forgejo'
    if [ "$CI_FORGE" = forgejo ] && [ -z "${CI_FORGE_URL:-}" ]; then
        ask CI_FORGE_URL "The Forgejo's address (e.g. https://git.example.org)"
        setting CI_FORGE_URL "${CI_FORGE_URL%/}"
        CI_FORGE_URL="${CI_FORGE_URL%/}"
    fi
    if [ -z "${CI_ADMINS:-}" ]; then
        ask CI_ADMINS "Your login on $CI_FORGE (Woodpecker admin; several: comma separated)"
        setting CI_ADMINS "$CI_ADMINS"
    fi
    if [ -z "${CI_ORGS+set}" ]; then
        ask CI_ORGS "Only members of these organisations may sign up (comma separated, empty: \
nobody; the admins add users by hand)" ""
        setting CI_ORGS "$CI_ORGS"
    fi
    if [ -z "${CI_GRPC_HOST+set}" ]; then
        ask CI_GRPC_HOST "A second DNS name for agents on other boxes (empty: none)" ""
        setting CI_GRPC_HOST "$CI_GRPC_HOST"
    fi
    valid CI_HOST '[a-z0-9.-]+'
    valid CI_ADMINS '[A-Za-z0-9._,-]+'
    valid CI_ORGS '[A-Za-z0-9._,-]*'
    # The longest a workflow may run, in minutes; each repository picks its own up to this.
    [ -n "${CI_MAX_TIMEOUT:-}" ] || setting CI_MAX_TIMEOUT 360
    CI_MAX_TIMEOUT="${CI_MAX_TIMEOUT:-360}"
    valid CI_MAX_TIMEOUT '[1-9][0-9]*'
    valid CI_GRPC_HOST '[a-z0-9.-]*'
    [ "$CI_FORGE" = github ] || valid CI_FORGE_URL 'https://[a-z0-9.:-]+(/[A-Za-z0-9._/-]*)?'
else
    if [ -z "${CI_SERVER_GRPC:-}" ]; then
        ask CI_SERVER_GRPC "The server's agent address (its CI_GRPC_HOST)"
        setting CI_SERVER_GRPC "$CI_SERVER_GRPC"
    fi
    valid CI_SERVER_GRPC '[a-z0-9.-]+'
fi

# --- Secrets -------------------------------------------------------------------------------------
if [ "$mode" = agent ] && [ ! -s "$etc/agent-secret" ]; then
    echo "The server's agent secret: on the server, cat $etc/agent-secret"
    ask_secret "$etc/agent-secret" "Agent secret"
fi
if [ "$mode" = server ] && [ ! -s "$etc/agent-secret" ]; then
    (umask 077; head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$etc/agent-secret")
fi
oauth_new=""
if [ "$mode" = server ] && { [ ! -s "$etc/forge-client-id" ] || \
    [ ! -s "$etc/forge-client-secret" ]; }; then
    if [ "$CI_FORGE" = github ]; then
        where="github.com/settings/applications/new"
        [ -n "$CI_ORGS" ] && where="github.com/organizations/${CI_ORGS%%,*}/settings/applications"
        echo "Make a GitHub OAuth app (GitHub has no API for this, so it is a browser step):"
        echo "  $where -> New OAuth app"
        echo "  Application name:           Woodpecker ($CI_HOST)"
        echo "  Homepage URL:               https://$CI_HOST"
        echo "  Authorization callback URL: https://$CI_HOST/authorize"
        echo "  then Generate a new client secret."
        ask client_id "OAuth app Client ID"
        [ -n "$client_id" ] || fail "no Client ID given"
        printf '%s' "$client_id" > "$etc/forge-client-id"
        ask_secret "$etc/forge-client-secret" "OAuth app client secret"
    else
        # Forgejo makes OAuth apps over its API, with a short-lived token of the admin's.
        echo "A Forgejo access token of your own, scope write:user, to make the OAuth app:"
        echo "  $CI_FORGE_URL/user/settings/applications -> Generate token (delete it afterwards)"
        token=$(mktemp); tmpfiles+=("$token")
        ask_secret "$token" "Forgejo token"
        hdr=$(mktemp); tmpfiles+=("$hdr")
        (umask 077; printf 'Authorization: token %s\n' "$(cat "$token")" > "$hdr")
        out=$(mktemp); tmpfiles+=("$out")
        body=$(jq -n --arg n "Woodpecker ($CI_HOST)" --arg u "https://$CI_HOST/authorize" \
            '{name: $n, redirect_uris: [$u], confidential_client: true}')
        status=$(curl -sS -o "$out" -w '%{http_code}' -X POST -H @"$hdr" \
            -H 'Content-Type: application/json' --data "$body" \
            "$CI_FORGE_URL/api/v1/user/applications/oauth2")
        [ "$status" = 201 ] || fail "Forgejo answered $status making the OAuth app"
        jq -r .client_id "$out" > "$etc/forge-client-id"
        (umask 077; jq -r .client_secret "$out" > "$etc/forge-client-secret")
        rm -f "$out"
    fi
    oauth_new=1
fi
# woodpecker-server runs as uid and gid 1000 and silently skips a *_FILE it cannot read, so its
# secrets are group 1000. A change restarts the services below.
secrets_changed=$(
    for f in "$etc/agent-secret" "$etc/forge-client-secret"; do
        [ -f "$f" ] || continue
        chown -c root:1000 "$f"
        chmod -c 0640 "$f"
    done
    [ ! -f "$etc/forge-client-id" ] || chmod -c 0644 "$etc/forge-client-id"
)
[ -n "$oauth_new" ] && secrets_changed=1

# --- DNS -----------------------------------------------------------------------------------------
if [ "$mode" = server ]; then
    addrs=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1)
    for h in $CI_HOST $CI_GRPC_HOST; do
        resolved=$(getent ahostsv4 "$h" | awk 'NR==1 {print $1}' || true)
        [ -n "$resolved" ] || fail "$h does not resolve; add an A record for this box"
        grep -qx "$resolved" <<<"$addrs" ||
            fail "$h points at $resolved, which is not this box ($(paste -sd' ' <<<"$addrs"))"
    done
fi

# --- Packages ------------------------------------------------------------------------------------
pkgs=(docker.io docker-compose-v2 ca-certificates curl jq)
missing=()
for p in "${pkgs[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
if [ "${#missing[@]}" -gt 0 ]; then
    step "installing ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -q
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${missing[@]}"
fi
systemctl enable -q --now docker

# --- Docker's seccomp profile --------------------------------------------------------------------
# Nerva's IO is io_uring, which Docker's default profile refuses (Docker 25 and later). The steps
# must not be privileged for it (decision O4), so the daemon gets Docker's default profile plus
# the three io_uring syscalls (ops/ci/docker/README.md): it then applies to every container the
# daemon creates without a profile of its own, the Woodpecker steps included. Only when the profile
# sits beside this script (checked in Preflight; CI_SECCOMP=no skips it). Idempotent: the daemon restarts only if the profile or daemon.json
# changed, and a restart stops running containers (restart: unless-stopped brings them back; a
# running pipeline fails), so rerun it when the agent is idle.
seccomp_dst=/etc/docker/seccomp-io_uring.json
daemon_json=/etc/docker/daemon.json
if [ "$seccomp" = yes ]; then
    jq -e '.syscalls | map(select(.names | index("io_uring_setup"))) | length > 0' "$seccomp_src" >/dev/null ||
        fail "$seccomp_src does not allow io_uring_setup"
    install -d -m 0755 /etc/docker
    changed=no
    cmp -s "$seccomp_src" "$seccomp_dst" || { install -m 0644 "$seccomp_src" "$seccomp_dst"; changed=yes; }
    [ -s "$daemon_json" ] || echo '{}' > "$daemon_json"
    merged=$(mktemp); tmpfiles+=("$merged")
    jq --arg p "$seccomp_dst" '. + {"seccomp-profile": $p}' "$daemon_json" > "$merged" ||
        fail "$daemon_json is not valid JSON; fix it, then rerun"
    if [ "$(jq -S . "$merged")" != "$(jq -S . "$daemon_json")" ]; then
        install -m 0644 "$merged" "$daemon_json"
        changed=yes
    fi
    if [ "$changed" = yes ]; then
        step "Docker $(docker version --format '{{.Server.Version}}'): installing the io_uring seccomp profile, restarting Docker"
        systemctl restart docker
    fi
    msg=$(bash "$probe" 2>&1) ||
        fail "$msg (docker info: $(docker info --format '{{json .SecurityOptions}}'))"
else
    step "CI_SECCOMP=no: Docker keeps its default seccomp profile, which refuses io_uring (Nerva's CI steps will fail NRV-E1201)"
fi
if [ "$CI_KVM" = yes ]; then
    grep -q AMD /proc/cpuinfo && echo kvm_amd > /etc/modules-load.d/woodpecker-kvm.conf ||
        echo kvm_intel > /etc/modules-load.d/woodpecker-kvm.conf
fi

# --- Compose files -------------------------------------------------------------------------------
install -d -m 0755 "$opt"
labels=kvm=false; [ "$CI_KVM" = no ] || labels=kvm=true
new=$(mktemp); tmpfiles+=("$new")
agent_yaml() { # agent_yaml SERVER [GRPC_SECURE]
    cat <<EOF
  woodpecker-agent:
    image: docker.io/woodpeckerci/woodpecker-agent:$woodpecker_version
    restart: unless-stopped
    environment:
      WOODPECKER_SERVER: $1
      WOODPECKER_GRPC_SECURE: "${2:-false}"
      WOODPECKER_AGENT_SECRET_FILE: /run/secrets/agent-secret
      WOODPECKER_BACKEND: docker
      WOODPECKER_MAX_WORKFLOWS: "$CI_MAX_WORKFLOWS"
      WOODPECKER_HOSTNAME: $CI_AGENT_NAME
      WOODPECKER_AGENT_LABELS: $labels
    volumes:
      - woodpecker-agent:/etc/woodpecker
      - /var/run/docker.sock:/var/run/docker.sock
      - $etc/agent-secret:/run/secrets/agent-secret:ro
EOF
}
if [ "$mode" = server ]; then
    if [ "$CI_FORGE" = github ]; then
        forge_env="      WOODPECKER_GITHUB: \"true\"
      WOODPECKER_GITHUB_CLIENT_FILE: /run/secrets/forge-client-id
      WOODPECKER_GITHUB_SECRET_FILE: /run/secrets/forge-client-secret"
    else
        forge_env="      WOODPECKER_FORGEJO: \"true\"
      WOODPECKER_FORGEJO_URL: $CI_FORGE_URL
      WOODPECKER_FORGEJO_CLIENT_FILE: /run/secrets/forge-client-id
      WOODPECKER_FORGEJO_SECRET_FILE: /run/secrets/forge-client-secret"
    fi
    # Open sign-up only behind an organisation: with no CI_ORGS, anyone with a forge account
    # could sign up, enable a repository of their own and run its code on these machines.
    open=false orgs_env=""
    [ -n "$CI_ORGS" ] && open=true orgs_env="      WOODPECKER_ORGS: $CI_ORGS"
    cat > "$new" <<EOF
# Written by woodpecker-bootstrap.sh on every run; change $etc/ci.env and rerun it instead.
name: woodpecker
services:
  caddy:
    image: docker.io/library/caddy:$caddy_version
    restart: unless-stopped
    ports: ["80:80", "443:443"]
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy-data:/data
      - caddy-config:/config
  woodpecker-server:
    image: docker.io/woodpeckerci/woodpecker-server:$woodpecker_version
    restart: unless-stopped
    environment:
      WOODPECKER_HOST: https://$CI_HOST
      WOODPECKER_ADMIN: $CI_ADMINS
      WOODPECKER_OPEN: "$open"
      WOODPECKER_MAX_PIPELINE_TIMEOUT: "$CI_MAX_TIMEOUT"
$orgs_env
$forge_env
      WOODPECKER_AGENT_SECRET_FILE: /run/secrets/agent-secret
    volumes:
      - woodpecker-data:/var/lib/woodpecker
      - $etc/forge-client-id:/run/secrets/forge-client-id:ro
      - $etc/forge-client-secret:/run/secrets/forge-client-secret:ro
      - $etc/agent-secret:/run/secrets/agent-secret:ro
$(agent_yaml woodpecker-server:9000)
    depends_on: [woodpecker-server]
volumes:
  caddy-data:
  caddy-config:
  woodpecker-data:
  woodpecker-agent:
EOF
    {
        printf '%s {\n\treverse_proxy woodpecker-server:8000\n}\n' "$CI_HOST"
        [ -z "$CI_GRPC_HOST" ] ||
            printf '%s {\n\treverse_proxy h2c://woodpecker-server:9000\n}\n' "$CI_GRPC_HOST"
    } > "$opt/Caddyfile.new"
    if ! cmp -s "$opt/Caddyfile.new" "$opt/Caddyfile"; then
        mv "$opt/Caddyfile.new" "$opt/Caddyfile"; secrets_changed=1
    else
        rm "$opt/Caddyfile.new"
    fi
else
    cat > "$new" <<EOF
# Written by woodpecker-bootstrap.sh agent on every run; change $etc/ci.env and rerun it instead.
name: woodpecker
services:
$(agent_yaml "$CI_SERVER_GRPC:443" true)
volumes:
  woodpecker-agent:
EOF
fi
sed -i '/^$/d' "$new"
install -m 0644 "$new" "$opt/compose.yaml"

if command -v ufw >/dev/null && ufw status | grep -q '^Status: active' && [ "$mode" = server ]
then
    ufw allow 80/tcp >/dev/null
    ufw allow 443/tcp >/dev/null
fi

# --- Start ---------------------------------------------------------------------------------------
dc() { docker compose -f "$opt/compose.yaml" "$@"; }
step "starting $( [ "$mode" = server ] && echo 'Woodpecker and Caddy' || echo 'the agent')"
dc up -d --remove-orphans >/dev/null
if [ -n "$secrets_changed" ]; then
    dc restart >/dev/null
fi

version=""
if [ "$mode" = server ]; then
    ok=""
    for _ in $(seq 1 60); do
        if curl -fsS --max-time 5 "https://$CI_HOST/healthz" >/dev/null 2>&1; then ok=1; break; fi
        sleep 5
    done
    [ -n "$ok" ] || fail "https://$CI_HOST/healthz did not answer in 5 minutes; check DNS and \
that ports 80 and 443 are open (docker compose -f $opt/compose.yaml logs caddy)"
    version=$(curl -fsS "https://$CI_HOST/version" | jq -r '.version // "?"')
fi

# The agent must still run 30 s later, with no refusal or unreachable server in its log.
sleep 30
if ! dc ps --status running --services | grep -qx woodpecker-agent ||
    dc logs --since 30s woodpecker-agent 2>&1 |
        grep -qiE 'unauthenticated|permission denied|connection refused|no such host'; then
    dc logs --no-log-prefix --tail 20 woodpecker-agent >&2 || true
    fail "the agent is not running or cannot reach the server (its last lines are above)"
fi

if [ "$mode" = server ]; then
    echo "Log in at https://$CI_HOST with your $CI_FORGE account ($CI_ADMINS is admin)."
    echo "woodpecker-bootstrap: OK https://$CI_HOST (woodpecker ${version}, forge $CI_FORGE, \
agent $CI_AGENT_NAME, $CI_MAX_WORKFLOWS workflows, kvm $CI_KVM${CI_GRPC_HOST:+, agents at \
$CI_GRPC_HOST:443})"
else
    echo "woodpecker-bootstrap: OK agent $CI_AGENT_NAME -> $CI_SERVER_GRPC:443 \
($CI_MAX_WORKFLOWS workflows, kvm $CI_KVM)"
fi
