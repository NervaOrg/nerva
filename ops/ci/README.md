# Woodpecker and Forgejo on your own boxes

**Nerva's shape (2026-11):** GitHub (`NervaLog/nerva`) stays the forge. Woodpecker runs from
GitHub's webhooks (`forge = github`) on one bare-metal Hetzner auction server, which has
`/dev/kvm`, so section 1 is Robot, not `hcloud`. A separate Forgejo pull-mirrors the repository
every 5 minutes (`mirror_interval` in `ops/forgejo/forgejo-bootstrap.sh`), as a copy that does
not depend on GitHub. Forgejo serves ports 80 and 443 itself, as does Woodpecker's Caddy, so the two
cannot share one box as written.

The scripts: `ops/ci/woodpecker-bootstrap.sh` and `ops/forgejo/forgejo-bootstrap.sh`.

Two scripts, each run once as root on a fresh Ubuntu 24.04 box, safe to run again, ending in one
`OK` or `FAIL <why>` line:

| Script | Makes | Box |
|--------|-------|-----|
| `woodpecker-bootstrap.sh` | Woodpecker CI 3.20.1 (server + one agent) behind Caddy (Let's Encrypt), for a project on **GitHub or Forgejo**; `... agent` adds agents on more boxes | Hetzner Cloud VM, or a dedicated server if pipelines need `/dev/kvm` |
| `forgejo-bootstrap.sh` | Forgejo 15 LTS (signature checked), SQLite, built-in TLS, git over SSH on port 2222, registration closed, nightly dumps, optional pull mirrors of GitHub repos | the smallest Hetzner Cloud VM (x86 or Arm) |

Neither script depends on the Zigbox repository. They are generalised from Zigbox's
`ops/ci/bootstrap.sh` and `ops/backup/bootstrap.sh`, with the same rules: secrets are read without
echo and never land on a command line, settings live in `/etc/...` and the rerun asks only for
what is missing.

If you want both for one project, set up Forgejo first, then Woodpecker with `forge = forgejo`.

## 0. Tools on your laptop (once)

```bash
brew install hcloud
```

(Linux: download `hcloud-linux-amd64.tar.gz` from github.com/hetznercloud/cli/releases.)

An API token for the Hetzner Cloud project is a **browser step**, since Hetzner only issues tokens
in its console. Go to console.hetzner.com, then your project, then Security, then API tokens, then
Generate, with Read & Write. Then:

```bash
hcloud context create myproject
```

It asks for the token without echo. Upload your SSH public key once per project:

```bash
hcloud ssh-key create --name laptop --public-key-from-file ~/.ssh/id_ed25519.pub
```

## 1. A firewall and the box

One firewall for both kinds of box: SSH, HTTP and HTTPS, and 2222 for Forgejo's git over SSH.
All four rules are idempotent to re-add.

```bash
hcloud firewall create --name web 2>/dev/null || true
for port in 22 80 443 2222; do
  hcloud firewall add-rule web --direction in --protocol tcp --port "$port" \
    --source-ips 0.0.0.0/0 --source-ips ::/0 2>/dev/null || true
done
```

Choose a type and location: `hcloud server-type list`, `hcloud location list`.

- **Woodpecker:** about 1 workflow per 4 vCPUs (the script's default). A dedicated-vCPU type
  (`ccx..`) keeps build times steady.
- **Forgejo:** the smallest shared type is plenty for a few people.

```bash
hcloud server create --name ci-myproject --type ccx23 --image ubuntu-24.04 --location fsn1 \
  --ssh-key laptop --firewall web
```

```bash
hcloud server create --name git-myproject --type cax11 --image ubuntu-24.04 --location fsn1 \
  --ssh-key laptop --firewall web
```

```bash
hcloud server ip ci-myproject
```

**Pipelines that boot VMs (need `/dev/kvm`):** Hetzner Cloud VMs have no nested virtualisation, so
use a dedicated server. Order it in Robot (robot.hetzner.com). That is a browser step, because
`hcloud` does not cover dedicated servers. Pick Ubuntu 24.04 and your SSH key in the order. The
script detects `/dev/kvm` and offers it to pipelines as the agent label `kvm=true`. Robot's own
firewall is off by default; the script opens 80 and 443 in `ufw` if `ufw` is active.

## 2. DNS

Add an `A` record from the name to the box's IPv4, for example `ci.myproject.org` and
`git.myproject.org`. If your provider is Cloudflare, leave it unproxied (grey cloud): both get
their certificates over ports 80 and 443 themselves. For extra Woodpecker agents on other boxes,
add a second name for the server, such as `grpc.ci.myproject.org`. Both scripts refuse to go on
until the name resolves to the box.

## 3a. Forgejo

```bash
scp forgejo-bootstrap.sh root@git.myproject.org:
```

```bash
ssh -t root@git.myproject.org bash forgejo-bootstrap.sh
```

It asks for:

- the DNS name and a site name;
- the admin user and e-mail (Let's Encrypt writes to it);
- whether everything needs sign-in (default yes);
- the SSH port (default 2222; `0` for HTTPS only);
- optionally, GitHub repositories to keep as pull mirrors. A private repository also needs a
  read-only fine-grained token, a browser step because GitHub has no API that makes tokens:
  github.com/settings/personal-access-tokens/new, then Contents: Read-only.

The first password is kept in a file, not printed into scrollback:

```bash
ssh root@git.myproject.org cat /etc/forgejo-setup/admin-password
```

Log in, change the password under Settings, then Account, and delete the file:

```bash
ssh root@git.myproject.org rm /etc/forgejo-setup/admin-password
```

Lost it before changing it?

```bash
ssh -t root@git.myproject.org env FORGEJO_RESET_ADMIN=1 bash forgejo-bootstrap.sh
```

Then add your SSH key under Settings, then SSH keys, and use it:

```bash
git remote add origin ssh://git@git.myproject.org:2222/OWNER/REPO.git
```

**Check:** the last line reads `forgejo-bootstrap: OK https://git.myproject.org (...)`. Run
`systemctl list-timers forgejo-dump.timer` on the box to see the nightly dump scheduled.
`systemctl start forgejo-dump` makes one now, in `/var/backups/forgejo/`. Copy those off the box
now and then, or turn on Hetzner's server backups:

```bash
hcloud server enable-backup git-myproject
```

**Pull mirrors vs. Zigbox's backup.** Forgejo's built-in pull mirror follows GitHub exactly, every
5 minutes. A branch force-pushed or deleted on GitHub is force-pushed or deleted on the mirror
too. Nerva has no equivalent of Zigbox's `ops/backup/` (which archives every replaced tip) yet.

## 3b. Woodpecker

```bash
scp woodpecker-bootstrap.sh root@ci.myproject.org:
```

```bash
ssh -t root@ci.myproject.org bash woodpecker-bootstrap.sh
```

It asks for:

- the agent's name, workflows at once, and whether to offer KVM;
- the DNS name;
- `github` or `forgejo`;
- your login (it becomes the admin);
- which organisations may sign up (for Nerva, the organisation that owns the repository). Left
  empty, nobody can sign up and the admins add users by hand: an open sign-up would let anyone
  run code on the box;
- an optional second name for remote agents.

Then the OAuth app:

- **GitHub:** a browser step, because GitHub has no API that creates OAuth apps. The script prints
  the page and the exact values (homepage `https://ci...`, callback `https://ci.../authorize`).
  Paste the Client ID, then the secret (hidden).
- **Forgejo:** no browser. The script makes the OAuth app itself over Forgejo's API with a
  short-lived token. Make the token on the Forgejo box; it prints to your terminal only:

  ```bash
  ssh root@git.myproject.org runuser -u git -- /usr/local/bin/forgejo --config /etc/forgejo/app.ini --work-path /var/lib/forgejo admin user generate-access-token --username YOU --token-name woodpecker-setup --scopes write:user --raw
  ```

  Paste it at the hidden prompt. Afterwards, delete it in Forgejo under Settings, then
  Applications.

**Check:** the last line reads `woodpecker-bootstrap: OK https://ci.myproject.org (woodpecker
3.20.1, ...)`. Open the site and log in with the forge.

**Turn on a repository:** a browser step. Woodpecker's CLI needs a personal token that only the
web UI issues, so the UI is as short. Click Add repository, then Enable. A repository whose
pipelines need `privileged: true` (KVM, Docker-in-Docker) or host volumes must be marked
**Trusted** by an admin in its settings.

A first pipeline, `.woodpecker/check.yaml`:

```yaml
when:
  - event: [push, pull_request]
steps:
  - name: test
    image: docker.io/library/alpine:3.22
    commands:
      - echo hello from Woodpecker
```

For a step that needs KVM, add `labels: { kvm: "true" }` at the top of the file, and
`privileged: true` on the step (the repository must be Trusted).

## 4. More agents

On the server, set a second DNS name. Rerun the script after adding `CI_GRPC_HOST=grpc.ci...` to
`/etc/woodpecker/ci.env`. Then, on each new box (same steps 1 and 2, no DNS needed for the agent):

```bash
scp woodpecker-bootstrap.sh root@NEWBOX:
```

```bash
ssh -t root@NEWBOX bash woodpecker-bootstrap.sh agent
```

It asks for the server's gRPC name and the agent secret (hidden). Read the secret on the server
with `cat /etc/woodpecker/agent-secret`. The line it prints is `woodpecker-bootstrap: OK agent ...`,
and the agent appears under Admin, then Agents.

## 5. Running them

- **Upgrade:** change `woodpecker_version` / `caddy_version`, or `forgejo_version` (and
  `forgejo_key` if Forgejo rotated it), at the top of the script, then rerun it.
- **Change a setting:** edit `/etc/woodpecker/ci.env` or `/etc/forgejo-setup/forgejo.env`, then
  rerun. The compose file, the Caddyfile and `app.ini` are rewritten from those on every run.
- **Rotate the GitHub OAuth secret, or move forges:** delete `/etc/woodpecker/forge-client-*`,
  then rerun.
- **Woodpecker's data** (users, repos, logs, secrets) is the Docker volume
  `woodpecker_woodpecker-data`. Back it up with:

  ```bash
  docker run --rm -v woodpecker_woodpecker-data:/d -v /root:/out alpine tar czf /out/woodpecker-data.tgz -C /d .
  ```

- **Logs:**
  - Woodpecker: `docker compose -f /opt/woodpecker/compose.yaml logs -f`
  - Forgejo: `journalctl -u forgejo -f`

## Nerva on Woodpecker

Nerva's CI is plain scripts under `ci/`. GitHub's `ci.yml` and the workflows in `.woodpecker/`
both call `ci/job.sh <job>`, so the two run the same checks. Each `.woodpecker/*.yaml` file
runs `ci/woodpecker_step.sh <job>` in a pinned `ubuntu:24.04` image. That script installs the
base packages, skips a docs-only push (`ci/changes.sh`), and runs the job as an unprivileged
user `ci` under a timeout (75 minutes, 330 for the long searches; ci.yml's are 30 to 60, but here
a push runs 16 workflows on one box beside the simulator fleet). No step is privileged, and only a
push to `main` writes the shared caches (decision O4, `docs/decisions/O4-self-hosted-ci-trust.md`,
which also says what a pusher of any branch can still do here: read it before giving anyone write
access).

**Only the repository's own branches run here; forks never do (P147e).** Woodpecker can run a
pull request from a fork on this box, and a fork's code must never run on a self-hosted machine.
Set this up once. `nerva-woodpecker.sh` does steps 1 to 4: `host` on each agent box, and
`repo` from your laptop, where it also enables the repository:

```bash
scp nerva-woodpecker.sh root@ci.myproject.org:
```

```bash
ssh -t root@ci.myproject.org bash nerva-woodpecker.sh host
```

```bash
WOODPECKER_SERVER=https://ci.myproject.org WOODPECKER_TOKEN=... bash nerva-woodpecker.sh repo OWNER/nerva
```

The token is a Woodpecker admin's: your avatar, then *Personal access token*. What the two modes
set:

1. **Settings, General:** turn **Allow pull requests** off, and set **Require approval** to
   *forks* as a second line of defence. The workflows also only match `push` and `manual`
   events. Fork pull requests run on GitHub's hosted runners only.
2. **Settings, General:** set the repository's **Timeout** to 360 minutes, since the long fuzz
   runs take up to 330. The bootstrap lets a repository choose up to 360 (`CI_MAX_TIMEOUT`).
3. **Settings, Project:** mark the repository **Trusted** for *volumes* and *network* only, and
   not for *security*: no step is privileged. Every workflow mounts the host's cache, and
   Jepsen also mounts the host's Docker socket and uses the host's network to reach its five
   node containers. Mounting the Docker socket gives that step root on the box: it runs for
   this repository's own branches, so whoever can push one has it (decision O4).
4. **On every agent box, once: run `woodpecker-bootstrap.sh` from a checkout that has
   `docker/seccomp-io_uring.json` beside it** (the directory `ops/ci/`), then
   `nerva-woodpecker.sh host`. This is the owner's one-time step for decision O4. The bootstrap
   copies Docker's default seccomp profile plus the three io_uring syscalls
   (`ops/ci/docker/`) to `/etc/docker/seccomp-io_uring.json`, merges
   `"seccomp-profile": "/etc/docker/seccomp-io_uring.json"` into `/etc/docker/daemon.json`
   (keeping every other key) and restarts Docker, only if either changed. **The restart stops the
   containers running on the box: do it with no pipeline running**; the agent and the server come
   back (`restart: unless-stopped`). `nerva-woodpecker.sh host` refuses to go on if the daemon
   has no such profile (`io_uring_probe.sh`: it pulls the pinned ubuntu image, NRV-E1211 if it cannot, and
   runs `io_uring_setup` in a throwaway container), and every job checks io_uring first and fails with NRV-E1201 if it is
   refused. Without the profile there is no other way to run Nerva's IO in a step: do not make
   the steps privileged instead.

   `nerva-woodpecker.sh host` creates the cache directories:

   ```bash
   install -d -m 0755 -o 1001 -g 1001 /var/cache/nerva-ci /var/cache/nerva-ci/{main,branches,jepsen}
   ```

   `main/` holds the pinned Zig's archive (`tools/<sha256>.tar.xz`, checked on every use), Zig's
   global cache and a `.zig-cache` copy, written only by a push to `main` (its steps mount it
   writable; every other step mounts it `:ro`). `branches/<key>/` is one branch's own copy,
   seeded with a copy of main's global Zig cache (`zig/`; `zig-local/` starts empty), at most 8 of them, 12 GiB and 7 days each. Jobs hold a shared `flock`
   on what they use. Below 60 GiB free (`CI_FREE_MIN_GIB`), a job for `main` waits up to 10
   minutes (`CI_PRUNE_WAIT`) to hold `main/` alone and empties its Zig caches (never the
   toolchain), and a branch job empties every branch cache no job is using. A lock that stays busy
   is never waited on for good: the job warns (NRV-W1202) and runs.

   **When the disk fills** (a job fails with "No space left", or NRV-W1202 keeps appearing), with
   no pipeline running: `rm -rf /var/cache/nerva-ci/branches/*` empties every branch cache, and
   `rm -rf /var/cache/nerva-ci/main/zig /var/cache/nerva-ci/main/zig-local` main's Zig caches. The
   next jobs make them again. Do not delete `main/tools` unless the archive is damaged: a job
   checks it by its sha256 and downloads it again anyway (NRV-W1201). A pipeline killed half way
   leaves a `branches/*.partial.*` directory, which the next prune removes. A branch whose builds fail with
   `FileNotFound` has a half-written `zig-local`: `rm -rf /var/cache/nerva-ci/branches/b-<key>-*`.
5. **GitHub statuses:** each workflow reports as `ci/woodpecker/push/<file>`, for example
   `ci/woodpecker/push/check` or `ci/woodpecker/push/demo/1`. Whether any of them becomes a
   required check on `main` is the owner's choice. GitHub's own checks stay required either
   way, since forks only get those.

**By hand** (*Run pipeline* on the repository, with variables):

| Variables | Runs |
|---|---|
| none | every CI workflow, as a push would |
| `NERVA_RUN=fuzz`, `MINUTES=120` | `fuzz-long`: every fuzzer and the VOPR lanes on random seeds (fuzz.yml) |
| `NERVA_RUN=jepsen`, `ARGS=test ...`, `TEETH=true`, `JEPSEN_LAZYFS_PATCH=no` | one Jepsen run (jepsen.yml); a push to `jepsen/**` runs one too |

A cron job named `fuzz-long` (Settings, Cron) runs the long fuzz on a schedule. A Jepsen run
waits for any other on the box, since its containers have fixed names. Its store and memory
record stay in `/var/cache/nerva-ci/jepsen/` for 14 days. Do not run `ops/jepsen`'s nightly on
an agent box: it uses the same container names and does not take the lock.

While the move is under way, GitHub Actions still runs every workflow as before; Woodpecker runs
the same commands beside it. Perf nightly stays on GitHub: it measures on a dedicated Fly machine
(N56), and a shared CI box would only add noise.

To run a job by hand on any Linux box with the toolchain's needs (as root, in a scratch copy of
the tree, with `/cache` present):

```bash
CI_PIPELINE_EVENT=manual ci/woodpecker_step.sh check-code
```

## What was and was not tested

- Both scripts pass `bash -n` and `shellcheck`.
- The compose file and Caddyfile they generate were checked for all three shapes: GitHub server,
  Forgejo server, and remote agent. The YAML parses, and the forge settings are right for
  Woodpecker 3.20.1's flag names.
- The end-to-end path (Docker, ACME, OAuth, the agent registering) is the same code that runs
  Zigbox's CI at ci.zigbox.org and its backup Forgejo.
- These generic copies have **not** been run on a fresh box yet, and neither have these new parts:
  - the Forgejo OAuth-app step;
  - remote agents over gRPC through Caddy;
  - Forgejo's SSH server, mirrors and dumps.

  The first run on a new box is the test. A `FAIL` line says what to fix.
- Nerva's workflows, after decision O4 (no step privileged; main and branch caches):
  - **Run (in a scratch directory, by `ci/ci_test.sh`, in `check-scripts`):** every refusal of
    the `ci/` scripts but E1203, E1209 and E1210 (E1201 with a stand-in for the kernel's refusal; E1202 for a writable main cache in a branch's role and a
    missing mount; E1204 to E1208; W1201; W1202), and `ci_redact`; the cache rules (a
    branch's cache is a copy, not a link; main is untouched by a branch; the count bound; a cache
    in use is not pruned; main's prune and its busy case); the toolchain archive checked and
    replaced on main, never replaced by a branch. `ci/changes_test.sh` covers the docs-only skip.
    The seccomp profile's merge into `daemon.json` was run with `jq` on an empty file and on a file
    with other keys (idempotent). All the scripts pass `bash -n`; the `.woodpecker/*.yaml` and
    `ci.yml` parse as YAML.
  - **Not run:** no workflow has run on a Woodpecker server since this change. Not checked: that
    `woodpecker-cli lint` accepts the two-step files; that the step's `when:` choose the mounts
    as intended; that a `:ro` mount makes `ci_cache_check` see main as read-only (a root process
    in the container cannot write a read-only mount, but it was not run on Docker); that
    the profile lets a step create an io_uring on a real daemon (and so that a replica starts);
    that Jepsen works unprivileged (it needed `privileged` before, for the step's own use of
    `/dev/fuse`, if at all); the bootstrap's Docker restart; the Forgejo password reset through
    the API. The first push after the owner's step is the test.
- `nerva-woodpecker.sh`: its failure paths were run here. Its `repo` mode was checked only
  against the Woodpecker 3.20.1 client's API paths and field names, never against a server.
