---
id: O14
date: 2026-11-23
area: CI
amends: N68
---

# CI skips a class of tests only when nothing it reads changed

N68 lets a docs-only pull request skip every step. This generalises it: a pull request skips the
steps of a class of tests when the change cannot affect them.

## Decision

A class of tests may be skipped for a change only when all four hold:

1. its outcome is deterministic given its inputs;
2. its input set is known mechanically (not from memory, and not from a hand-written list);
3. no input changed against the pull request's merge base (the file list of the pull request);
4. its environment is pinned (toolchain, runner image, seeds).

Everything else runs. Fail closed:

- only a pull request is classified; a push to main, `release.yml`'s `workflow_call` and
  `workflow_dispatch` run everything;
- a changed file the classifier does not place, an empty list, a list shorter than the pull
  request's `changed_files`, or one at the API's 3000-file limit, makes `all` true;
- steps are skipped, not jobs, so every required check name keeps reporting (as in N68). A failed
  `changes` job leaves every output empty, and every condition is `!= 'false'`, so everything runs.

## Mechanism

- `.github/scripts/classify_changes.sh` reads file names on stdin and prints one `class=true|false`
  line per class (`--all`, `--expect N`). Classes: `all`, `binary` (src/, build.zig, zig/, VERSION:
  every suite but the keychain job), `any`, one per suite (`unit fuzz vopr targets integration api
  views release demo demo_r4 demo_r5 macos packaging ci_scripts`), `mac_keychain` and the derived
  `checks`. `all` and `binary` fold into the suites, so a job gates on its own class alone.
  `docs_only.sh` stays as it is: Woodpecker's `ci/changes.sh` uses it.
- `.github/scripts/classify_guard.py` (NRV-E1250), run by `classify_changes_test.sh` in ci.yml's
  `ci-scripts` job, reads build.zig and every script under `tests/**` with the Python AST, follows
  imports, `sys.path` and path joins, and fails when a suite reads a file outside its own directory
  that the classifier does not select that suite for. It also fails when ci.yml gates a step on a
  class the classifier does not print, or does not output one. The table test covers the
  fail-closed cases (empty list, unknown path, truncated list, 3000 lines).
- ci.yml: the `changes` job outputs every class; each job's steps are gated on its class. `checks`
  runs `check-code`, `check-scripts` (CI_SCRIPTS_TESTED=1) and `check-packages` as separate steps.
  VOPR's fixed seeds (1, 2, 5) are deterministic and gate on `vopr`; its random seed is not, and
  gates on `any` (anything that something reads), so the random search still runs on every
  non-docs change.
- packages.yml (fixes #13): the `paths:` list is gone; a `classify` job runs the classifier and the
  jobs run for `all`, `binary` or `packaging`. Its header comment now says what it does.

## Cross-suite reads found

`tests/api/api.py` is imported by `tests/errors/commands.py` (test:integration), so `tests/api/**`
and `tests/errors/**` select both `api` and `integration`. `demo/**` is read by the seat and canvas
demos. `docs/API.md` by `tests/api/docs_routes.py`, `docs/ERRORS.md` by unit tests and `ci_test.sh`,
`docs/INSTALL.md` by `tests/packaging/repos.py`, and UPSTREAM.md, docs/QUICKSTART.md and
docs/releases/packages.md by the CI scripts' tests.

## Cost

A new directory or kind of file is not placed, so it runs everything until a rule is added; the
guard catches only the reads it can see statically (a path built at runtime is invisible to it).
Skipped suites are not re-proved on the pull request: a main push runs everything, so a miss shows
there, not in the merged change.

## Future work (not decided here)

- Woodpecker uses the same classifier (it still uses `docs_only.sh` and `ci/changes.sh`).
- Cache VOPR results by the binary's hash, so an unchanged binary replays no seed.
- Move random fuzzing and the random VOPR search to cron or the simulation fleet, off the pull
  request path.
- A runtime audit hook: record the files each suite actually opens, and compare them with the
  classifier's table, to catch reads the static guard cannot see.
