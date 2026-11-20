#!/usr/bin/env bash
# Forgejo on one small box (Ubuntu 24.04 or Debian 12/13, x86_64 or arm64): the signed release
# binary, SQLite, its own TLS through Let's Encrypt, its own SSH server for git on another port
# than the box's sshd, registration closed, a nightly `forgejo dump`, and optionally pull mirrors
# of GitHub repositories. Run it as root on the box:
#
#   bash forgejo-bootstrap.sh
#
# It asks for what it does not have yet and keeps the answers in /etc/forgejo-setup/forgejo.env
# (not secret). Safe to run again: it asks only for what is missing and changes only what differs.
# FORGEJO_RESET_ADMIN=1 on a rerun sets a new first-login password for the admin. Its last line is
# `forgejo-bootstrap: OK ...` or `forgejo-bootstrap: FAIL <why>`.
set -euo pipefail

# Forgejo's long-term-support line (supported until 2027-07-15), signed by Forgejo's release key
# (https://forgejo.org/download/). To upgrade, change these two and rerun.
forgejo_version=15.0.12
forgejo_key=EB114F5E6C0DC2BCDD183550A4B61A2DC5923710
# How often a pull mirror fetches. Forgejo refuses an interval under [mirror] MIN_INTERVAL (10m by
# default), so app.ini sets both to this.
mirror_interval=5m

etc=/etc/forgejo-setup
fj_data=/var/lib/forgejo
fj_etc=/etc/forgejo
fj=/usr/local/bin/forgejo
dumps=/var/backups/forgejo

fail() { echo "forgejo-bootstrap: FAIL $*"; exit 1; }
step() { echo "forgejo-bootstrap: $*"; }
cleanup=()
trap 'rm -rf "${cleanup[@]}"' EXIT

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
    (umask 077; printf '%s' "$answer" > "$1")
}
setting() { # setting NAME VALUE: writes NAME="VALUE" into forgejo.env, replacing an earlier line.
    grep -v "^$1=" "$etc/forgejo.env" > "$etc/forgejo.env.new" || true
    printf '%s="%s"\n' "$1" "$2" >> "$etc/forgejo.env.new"
    mv "$etc/forgejo.env.new" "$etc/forgejo.env"
}
valid() { # valid NAME REGEX
    [[ "${!1:-}" =~ ^$2$ ]] || fail "$1='${!1:-}' in $etc/forgejo.env is not valid"
}

# --- Preflight -----------------------------------------------------------------------------------
[ "$(id -u)" = 0 ] || fail "run as root"
. /etc/os-release
case "${ID:-}-${VERSION_ID:-}" in
    ubuntu-24.04 | debian-12 | debian-13) ;;
    *) fail "this script is written for Ubuntu 24.04 or Debian 12 or 13, found ${PRETTY_NAME:-?}" ;;
esac
case "$(uname -m)" in
    x86_64) arch=amd64 ;;
    aarch64) arch=arm64 ;;
    *) fail "Forgejo publishes x86_64 and arm64 binaries; this box is $(uname -m)" ;;
esac
pkgs=(ca-certificates curl git gnupg jq)
missing=()
for p in "${pkgs[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
if [ "${#missing[@]}" -gt 0 ]; then
    step "installing ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -q
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${missing[@]}"
fi

# --- Settings ------------------------------------------------------------------------------------
install -d -m 0711 "$etc"
touch "$etc/forgejo.env"
chmod 0644 "$etc/forgejo.env"
set -a; . "$etc/forgejo.env"; set +a
if [ -z "${FJ_HOST:-}" ]; then
    ask FJ_HOST "DNS name of this box (e.g. git.example.org)"; setting FJ_HOST "$FJ_HOST"
fi
if [ -z "${FJ_NAME:-}" ]; then
    ask FJ_NAME "Site name shown in the page title" "Forgejo"; setting FJ_NAME "$FJ_NAME"
fi
if [ -z "${FJ_ADMIN:-}" ]; then
    ask FJ_ADMIN "Admin user name (not 'admin', which Forgejo reserves)"
    setting FJ_ADMIN "$FJ_ADMIN"
fi
if [ -z "${FJ_EMAIL:-}" ]; then
    ask FJ_EMAIL "Admin e-mail (Let's Encrypt writes here about the certificate)"
    setting FJ_EMAIL "$FJ_EMAIL"
fi
if [ -z "${FJ_PRIVATE:-}" ]; then
    ask FJ_PRIVATE "Require sign-in to see anything at all? yes or no" yes
    setting FJ_PRIVATE "$FJ_PRIVATE"
fi
if [ -z "${FJ_SSH_PORT:-}" ]; then
    ask FJ_SSH_PORT "Port for git over SSH (0: HTTPS only)" 2222; setting FJ_SSH_PORT "$FJ_SSH_PORT"
fi
if [ -z "${FJ_MIRRORS+set}" ]; then
    ask FJ_MIRRORS "GitHub repositories to pull-mirror, OWNER/NAME separated by spaces (empty: \
none)" ""
    setting FJ_MIRRORS "$FJ_MIRRORS"
fi
valid FJ_HOST '[a-z0-9.-]+'
valid FJ_NAME '[A-Za-z0-9 ._-]+'
valid FJ_ADMIN '[A-Za-z0-9._-]+'
valid FJ_EMAIL '[^ "@]+@[^ "@]+'
valid FJ_PRIVATE 'yes|no'
valid FJ_SSH_PORT '[0-9]+'
valid FJ_MIRRORS '([A-Za-z0-9._-]+/[A-Za-z0-9._-]+ ?)*'
[ "$FJ_SSH_PORT" != 22 ] || fail "FJ_SSH_PORT=22 is the box's own sshd; take another (2222)"
if [ -n "$FJ_MIRRORS" ] && [ ! -e "$etc/github-token" ]; then
    echo "A read-only GitHub token for private repositories (empty if all are public):"
    echo "  github.com/settings/personal-access-tokens/new, Contents: Read-only (browser only:"
    echo "  GitHub has no API that makes tokens)."
    ask_secret "$etc/github-token" "GitHub token"
    chmod 0400 "$etc/github-token"
fi

# --- DNS and disk --------------------------------------------------------------------------------
resolved=$(getent ahostsv4 "$FJ_HOST" | awk 'NR==1 {print $1}' || true)
[ -n "$resolved" ] || fail "$FJ_HOST does not resolve; add an A record for this box"
addrs=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1)
grep -qx "$resolved" <<<"$addrs" ||
    fail "$FJ_HOST points at $resolved, which is not this box ($(paste -sd' ' <<<"$addrs"))"
free_gb=$(df -BG --output=avail /var/lib | tail -1 | tr -dc 0-9)
[ "$free_gb" -ge 5 ] || fail "/var/lib has ${free_gb} GiB free; Forgejo needs at least 5"

# --- Forgejo binary ------------------------------------------------------------------------------
fj_changed=""
if ! "$fj" --version 2>/dev/null | grep -qE "version $forgejo_version([+ ]|$)"; then
    step "installing Forgejo $forgejo_version (signature checked against $forgejo_key)"
    tmp=$(mktemp -d); cleanup+=("$tmp")
    base="https://codeberg.org/forgejo/forgejo/releases/download/v$forgejo_version"
    bin="forgejo-$forgejo_version-linux-$arch"
    curl -fsSL --retry 3 -o "$tmp/$bin" "$base/$bin"
    curl -fsSL --retry 3 -o "$tmp/$bin.asc" "$base/$bin.asc"
    install -d -m 0700 "$tmp/gnupg"
    gpg --homedir "$tmp/gnupg" -q --keyserver hkps://keys.openpgp.org --recv-keys "$forgejo_key" \
        2>/dev/null || fail "could not fetch Forgejo's key $forgejo_key from keys.openpgp.org"
    # VALIDSIG's last field is the primary key's fingerprint, whichever subkey signed.
    signer=$(gpg --homedir "$tmp/gnupg" --status-fd 1 --verify "$tmp/$bin.asc" "$tmp/$bin" \
        2>/dev/null | awk '$2 == "VALIDSIG" {print $NF}')
    [ "$signer" = "$forgejo_key" ] ||
        fail "$bin is not signed by Forgejo's release key (signer: ${signer:-none})"
    install -m 0755 "$tmp/$bin" "$fj"
    fj_changed=1
fi
if ! id git >/dev/null 2>&1; then
    adduser --system --shell /bin/bash --gecos 'Git Version Control' --group \
        --disabled-password --home /home/git git >/dev/null
fi
install -d -m 0750 -o git -g git "$fj_data"
install -d -m 0750 -o root -g git "$fj_etc"

# --- app.ini, written afresh on every run from forgejo.env -------------------------------------
if [ ! -s "$etc/forgejo-secrets.env" ]; then
    (umask 077; {
        echo "SECRET_KEY=$("$fj" generate secret SECRET_KEY)"
        echo "INTERNAL_TOKEN=$("$fj" generate secret INTERNAL_TOKEN)"
        echo "JWT_SECRET=$("$fj" generate secret JWT_SECRET)"
    } > "$etc/forgejo-secrets.env")
fi
if ! grep -q '^LFS_JWT_SECRET=' "$etc/forgejo-secrets.env"; then
    echo "LFS_JWT_SECRET=$("$fj" generate secret LFS_JWT_SECRET)" >> "$etc/forgejo-secrets.env"
fi
. "$etc/forgejo-secrets.env"
signin=true; private=private
[ "$FJ_PRIVATE" = yes ] || { signin=false; private=last; }
if [ "$FJ_SSH_PORT" = 0 ]; then
    ssh_ini="DISABLE_SSH = true"
else
    ssh_ini="DISABLE_SSH = false
START_SSH_SERVER = true
SSH_PORT = $FJ_SSH_PORT
SSH_LISTEN_PORT = $FJ_SSH_PORT"
fi
ini=$(mktemp); cleanup+=("$ini")
cat > "$ini" <<EOF
; Written by forgejo-bootstrap.sh on every run; change $etc/forgejo.env and rerun it instead.
APP_NAME = $FJ_NAME
RUN_USER = git
RUN_MODE = prod
WORK_PATH = $fj_data

[server]
PROTOCOL = https
DOMAIN = $FJ_HOST
SSH_DOMAIN = $FJ_HOST
ROOT_URL = https://$FJ_HOST/
HTTP_PORT = 443
REDIRECT_OTHER_PORT = true
PORT_TO_REDIRECT = 80
ENABLE_ACME = true
ACME_ACCEPTTOS = true
ACME_DIRECTORY = $fj_data/acme
ACME_EMAIL = $FJ_EMAIL
$ssh_ini
OFFLINE_MODE = true
APP_DATA_PATH = $fj_data/data
LFS_START_SERVER = true
LFS_JWT_SECRET = $LFS_JWT_SECRET

[database]
DB_TYPE = sqlite3
PATH = $fj_data/data/forgejo.db

[repository]
ROOT = $fj_data/repositories
DEFAULT_PRIVATE = $private

[security]
INSTALL_LOCK = true
SECRET_KEY = $SECRET_KEY
INTERNAL_TOKEN = $INTERNAL_TOKEN

[oauth2]
JWT_SECRET = $JWT_SECRET

[service]
DISABLE_REGISTRATION = true
REQUIRE_SIGNIN_VIEW = $signin

[mirror]
ENABLED = true
DEFAULT_INTERVAL = $mirror_interval
MIN_INTERVAL = $mirror_interval

[log]
MODE = console
LEVEL = Info

[cron.update_checker]
ENABLED = false
EOF
if ! cmp -s "$ini" "$fj_etc/app.ini"; then
    install -m 0640 -o root -g git "$ini" "$fj_etc/app.ini"
    fj_changed=1
fi

unit=/etc/systemd/system/forgejo.service
cat > "$unit.new" <<EOF
[Unit]
Description=Forgejo
After=network-online.target
Wants=network-online.target

[Service]
User=git
Group=git
WorkingDirectory=$fj_data
Environment=USER=git HOME=/home/git FORGEJO_WORK_DIR=$fj_data
ExecStart=$fj web --config $fj_etc/app.ini
# Ports 80 and 443 without root.
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
if ! cmp -s "$unit.new" "$unit"; then mv "$unit.new" "$unit"; fj_changed=1; else rm "$unit.new"; fi

# A nightly dump (database, repositories, settings) into $dumps; the last 7 are kept.
install -d -m 0750 -o git -g git "$dumps"
cat > /usr/local/lib/forgejo-dump.sh <<EOF
#!/bin/sh
# Written by forgejo-bootstrap.sh: one dump into $dumps, then all but the newest 7 removed.
set -eu
cd $dumps
$fj dump --config $fj_etc/app.ini --type tar.zst --file forgejo-dump.new.tar.zst
mv forgejo-dump.new.tar.zst "forgejo-\$(date -u +%Y%m%dT%H%M%SZ).tar.zst"
ls -1t forgejo-2*.tar.zst | tail -n +8 | xargs -r rm --
EOF
chmod 0755 /usr/local/lib/forgejo-dump.sh
cat > /etc/systemd/system/forgejo-dump.service <<EOF
[Unit]
Description=Dump Forgejo into $dumps, keeping the last 7

[Service]
Type=oneshot
User=git
Group=git
Environment=USER=git HOME=/home/git FORGEJO_WORK_DIR=$fj_data
ExecStart=/usr/local/lib/forgejo-dump.sh
EOF
cat > /etc/systemd/system/forgejo-dump.timer <<EOF
[Unit]
Description=Dump Forgejo every night

[Timer]
OnCalendar=*-*-* 03:17:00
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable -q forgejo
systemctl enable -q --now forgejo-dump.timer
if [ -n "$fj_changed" ]; then
    step "starting Forgejo"
    systemctl restart forgejo
fi

if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
    ufw allow 80/tcp >/dev/null
    ufw allow 443/tcp >/dev/null
    [ "$FJ_SSH_PORT" = 0 ] || ufw allow "$FJ_SSH_PORT/tcp" >/dev/null
fi

ok=""
for _ in $(seq 1 60); do
    if curl -fsS --max-time 5 "https://$FJ_HOST/api/healthz" >/dev/null 2>&1; then ok=1; break; fi
    sleep 5
done
[ -n "$ok" ] || fail "https://$FJ_HOST/api/healthz did not answer in 5 minutes; check that \
$FJ_HOST points at this box and ports 80 and 443 are open (journalctl -u forgejo)"

# --- The admin -----------------------------------------------------------------------------------
fja() { # fja ARGS: forgejo admin ARGS, as the user git.
    runuser -u git -- env HOME=/home/git "$fj" --config "$fj_etc/app.ini" --work-path "$fj_data" \
        admin "$@"
}
# The first password is kept in admin-password (root only, 0400) instead of scrolling away. Never
# --must-change-password: Forgejo answers 403 to every API call of such a user, the mirrors' too.
admin_pw="$etc/admin-password"
if ! fja user list --admin | awk 'NR > 1 {print $2}' | grep -qx "$FJ_ADMIN"; then
    step "creating the admin $FJ_ADMIN"
    created=$(fja user create --username "$FJ_ADMIN" --email "$FJ_EMAIL" --admin \
        --random-password 2>&1) || fail "Forgejo refused the admin: $(tail -1 <<<"$created")"
    pw=$(sed -n "s/.*generated random password is '\(.*\)'.*/\1/p" <<<"$created")
    [ -n "$pw" ] || fail "Forgejo created $FJ_ADMIN but printed no password"
    (umask 077; printf '%s\n' "$pw" > "$admin_pw"); chmod 0400 "$admin_pw"
elif [ "${FORGEJO_RESET_ADMIN:-}" = 1 ]; then
    step "setting a new first-login password for $FJ_ADMIN"
    pw=$(head -c 18 /dev/urandom | base64)
    # `admin user change-password --password` would put the password on the command line, where
    # `ps` shows it to every user of the box. The API takes it in a request body from a file, with
    # the token in a header file, neither on a command line.
    reset_hdr=$(mktemp); cleanup+=("$reset_hdr")
    reset_body=$(mktemp); cleanup+=("$reset_body")
    (umask 077
     printf 'Authorization: token %s\n' "$(fja user generate-access-token --username "$FJ_ADMIN" --raw \
         --token-name "forgejo-reset-$(date -u +%s)" --scopes write:admin)" > "$reset_hdr"
     jq -n --arg u "$FJ_ADMIN" --arg p "$pw" \
         '{login_name: $u, source_id: 0, password: $p, must_change_password: false}' > "$reset_body")
    [ "$(curl -sS -o /dev/null -w '%{http_code}' -X PATCH -H @"$reset_hdr" -H 'Content-Type: application/json' \
        --data @"$reset_body" "https://$FJ_HOST/api/v1/admin/users/$FJ_ADMIN")" = 200 ] ||
        fail "Forgejo refused the new password (the admin API did not answer 200)"
    rm -f "$admin_pw"; (umask 077; printf '%s\n' "$pw" > "$admin_pw"); chmod 0400 "$admin_pw"
fi

# --- Pull mirrors --------------------------------------------------------------------------------
mirrored=0
if [ -n "$FJ_MIRRORS" ]; then
    if [ ! -s "$etc/forgejo-token" ]; then
        (umask 077; fja user generate-access-token --username "$FJ_ADMIN" --raw \
            --token-name "forgejo-bootstrap-$(date -u +%s)" \
            --scopes write:repository,write:organization > "$etc/forgejo-token")
    fi
    hdr=$(mktemp); cleanup+=("$hdr")
    (umask 077; printf 'Authorization: token %s\n' "$(cat "$etc/forgejo-token")" > "$hdr")
    api() { # api METHOD PATH [JSON-FILE]: prints the HTTP status.
        curl -sS -o /dev/null -w '%{http_code}' -X "$1" -H @"$hdr" \
            -H 'Content-Type: application/json' ${3:+--data @"$3"} "https://$FJ_HOST/api/v1$2"
    }
    body=$(mktemp); cleanup+=("$body")
    for repo in $FJ_MIRRORS; do
        owner=${repo%/*} name=${repo#*/}
        status=$(api GET "/orgs/$owner")
        if [ "$status" = 404 ]; then
            step "creating the organisation $owner"
            jq -n --arg o "$owner" '{username: $o, visibility: "private"}' > "$body"
            status=$(api POST /orgs "$body")
            [ "$status" = 201 ] || fail "Forgejo answered $status creating the organisation $owner"
        elif [ "$status" != 200 ]; then
            fail "Forgejo answered $status reading the organisation $owner"
        fi
        if [ "$(api GET "/repos/$repo")" != 200 ]; then
            step "mirroring github.com/$repo (every $mirror_interval)"
            (umask 077; jq -n --arg o "$owner" --arg n "$name" \
                --arg u "https://github.com/$repo.git" --arg iv "$mirror_interval" --rawfile t "$etc/github-token" \
                '{clone_addr: $u, repo_owner: $o, repo_name: $n, mirror: true, private: true,
                  mirror_interval: $iv, service: "git"}
                 + (if $t == "" then {} else {auth_username: "x-access-token", auth_password: $t}
                    end)' > "$body")
            status=$(api POST /repos/migrate "$body")
            [ "$status" = 201 ] || fail "Forgejo answered $status mirroring $repo (a private \
repository needs the token; rm $etc/github-token and rerun to give one)"
        fi
        mirrored=$((mirrored + 1))
    done
fi

if [ -s "$admin_pw" ]; then
    echo "Log in at https://$FJ_HOST as $FJ_ADMIN with the password in $admin_pw (cat it as"
    echo "root), change it under Settings, Account, then delete the file."
fi
ssh_note="ssh port $FJ_SSH_PORT"; [ "$FJ_SSH_PORT" != 0 ] || ssh_note="no ssh"
echo "forgejo-bootstrap: OK https://$FJ_HOST (Forgejo $forgejo_version, $ssh_note, \
$mirrored mirrors, nightly dumps in $dumps)"
