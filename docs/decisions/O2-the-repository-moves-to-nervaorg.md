---
id: O2
date: 2026-11-20
area: Releases
---

# The repository moves to NervaOrg; its own pull requests are numbered O

**Decision.** Nerva's home is `NervaOrg/nerva` (owner, in session, 2026-11-20). The account that
owned `NervaLog` is suspended: its source survives, its issues, pull requests, Actions runs,
releases, environments, secrets and GitHub App do not. The repositories beside it move too:

| Was | Is |
|---|---|
| `NervaLog/nerva` | `NervaOrg/nerva` |
| `NervaLog/homebrew-tap` (`brew tap nervalog/tap`) | `NervaOrg/homebrew-tap` (`brew tap nervaorg/tap`) |
| `NervaLog/nervalog.github.io` | `NervaOrg/nerva-site` (it already deploys as the Worker `nerva-site`, P410) |

1. Every file that acts on a repository name (the workflows, the release, site and package
   scripts and their tests, packaging, the fleet's and Jepsen's setup, the Mac release tool, and
   the docs that tell an operator what to run) names the new one.
2. A record stays as written: the decision files, the worklog, the retros, the briefs, the past
   releases' CHANGELOG sections and release documents, the demos' run links, and every link to a
   numbered `NervaLog/nerva` issue, pull request or run. Those links are dead now, but rewriting
   them would point at another tracker's numbers.
3. `NervaOrg/nerva`'s pull request numbers restart at 1 and collide with the old ones from #87 on.
   Its decisions are `O<number>` and its worklog notes `worklog/O<number>.md`. A `P` or bare number
   in a file written before this move names the old tracker.
4. The release signing key stays: the owner kept `949F066FB37C440E54B2A902AEA7B66340A6DBAB`, the
   one `packaging/keys/nerva-release.asc` pins, so apt and dnf installs keep trusting new releases.
   Everything else the release chain needs is set up again on `NervaOrg` (docs/releases/automation.md):
   the environments, their secrets and variables, the GitHub App, the tap and the site repository.
   The Developer ID certificate is the owner's Apple account's, re-exported; the notary key is new.

**Reason.** The old owner cannot be reached, and every repository name in the release chain is a
place it writes to. One prefix per tracker keeps a citation unambiguous without renumbering a
merged file.

**Cost.** Homebrew users untap `nervalog/tap` and tap `nervaorg/tap` once (CHANGELOG, v0.7.2). Links
to the old issues, runs and releases no longer resolve, including the R4 and R5 demo runs and the
v0.7.1 assets. The release chain runs for the first time with new secrets, so v0.7.2's rehearsal on
a prerelease (P474 a) cannot be waived in practice.
