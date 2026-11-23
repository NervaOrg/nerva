---
id: O14
date: 2026-11-23
area: CI
amends: N68
---

# A pull request skips a class of tests only when this change cannot have caused a regression in it

N68 lets a docs-only pull request skip every step. This generalises it: a pull request skips the
steps of a class of tests when the change cannot have broken them.

## What a skip claims

A skip on a pull request claims one thing: **this change cannot have caused a regression in that
class.** It does not claim that the class is green, that it is deterministic, or that its
environment is unchanged. It holds when:

1. the class's inputs are known: every file its suites read or run is placed by the classifier,
   found mechanically (by `classify_guard.py`, below) and not from memory; and
2. none of those files is in the pull request's file list (both names of a rename: the old path is a
   deletion).

Everything else runs. Fail closed:

- only a pull request is classified; a push to main (every push, Markdown included: `ci.yml`'s
  `push` trigger has no `paths-ignore`, and the guard checks that), `release.yml`'s `workflow_call`
  and `workflow_dispatch` run everything;
- a pull request that changes `.github/workflows/**`, `.github/scripts/classify_*` or
  `.github/actions/**` (either name of a rename) runs everything, decided in the workflow's own
  `classify` step from the pull request's file list, outside `classify_changes.sh`: the classifier
  never gates a change to itself, and a broken one cannot skip the run that changes it;
- a changed file the classifier does not place, an empty list, a list shorter than the pull
  request's `changed_files`, one at the API's 3000-file limit, a list the API could not give, or a
  list for another head than the run's (the pull request's head is read before and after the list
  and must equal the event's `pull_request.head.sha`) makes `all` true;
- steps are skipped, not jobs, so every required check name keeps reporting (as in N68). A failed
  `changes` job leaves every output empty, and every condition is `!= 'false'`, so everything runs.

## What a skip does not claim

Determinism and a pinned environment are what a *result* needs to vouch for a commit, not what a
skip needs. A skip says nothing about either, and no skip certifies a class:

- **Nondeterministic classes.** `integration`, `api`, `release`, `demo`, `demo_r4` and `demo_r5` run
  real processes, with wall-clock timeouts (the chaos demos run on about 75 s of real time) and
  random choices. Their flakes and races are what these suites are for. A green run vouches for
  its own run only; a skipped one vouches for nothing.
- **Classes that depend on their environment.** The runner images (`ubuntu-24.04`, `macos-15`,
  `macos-15-intel`) roll, `python3` and the packaging tools are whatever the image or the pinned
  installer gives, and `actions/cache@v4` is a moving tag. This reaches every class, `unit`,
  `fuzz` (fixed seed) and `vopr` (fixed seeds) included.
- **Never selected by diff.** VOPR's random seed runs on `any` change (anything something reads).
  The latency scenario's exclusivity is #12's subject. Random fuzzing and the simulation fleet,
  and Jepsen, run elsewhere (the fleet, the nightly) and are not on the pull request path.

Flakes and environment drift are caught by what runs everything: every push to main, which is `all`,
and by the classes above that no diff skips. A skipped flake or a drifted image shows on main, not
in the merged change, and is then a pre-existing bug for an issue (CLAUDE.md).

## Mechanism

- `.github/scripts/classify_changes.sh` reads file names on stdin and prints one `class=true|false`
  line per class (`--all`, `--expect N`: at least N files, one per line, a rename as
  `new<TAB>old`, so a rename counts once and lists both names; fewer is a cut list). Classes: `all`, `binary` (src/, build.zig, zig/, VERSION: every suite but the keychain
  job), `any`, one per suite (`unit fuzz vopr targets integration api views release demo demo_r4
  demo_r5 macos packaging ci_scripts`), `mac_keychain` and the derived `checks`. `all` and `binary`
  fold into the suites, so a job gates on its own class alone. `docs_only.sh` stays as it is:
  Woodpecker's `ci/changes.sh` uses it.
- `.github/scripts/classify_pr.sh` fetches the list (one line per file: `filename`, then
  `previous_filename` for a rename) and the head, and fails closed as above (NRV-E1252). ci.yml's
  `changes` job and packages.yml's `classify` job run it, then force their classes for a change to
  the plumbing (above) with a second read of the file list; a failed read fails the step, and every
  condition is `!= 'false'`, so everything runs. The classifier's usage error is NRV-E1251.
- `.github/scripts/classify_guard.py` (NRV-E1250), run by `classify_changes_test.sh` in ci.yml's
  `ci-scripts` job, checks:
  - **Reads.** From the scripts build.zig's steps run, ci/job.sh's `check_code`, `check_scripts`
    and `check_packages` run, tests/packaging, tests/macos and ci/ci_test.sh, it follows what each
    reads: in Python by the syntax tree (imports, `sys.path`, `os.path.join`, `pathlib`, f-strings
    and `+`, literals), in shell by the literal repository paths and `$here/x`, `$root/x` of the
    directory the script found for itself. For each file reached, the classifier must select the
    class that reaches it. A file whose class includes `all` is not followed further (a change to it
    runs everything). The Zig unit tests' reads of files outside `src/` are checked the same way
    (literals, consts, `@embedFile`).
  - **What it cannot evaluate fails closed.** A path built from parts the guard cannot evaluate
    (`os.path.join(root, "docs", ...)`, `Path(root) / "docs"` with an unknown `root` included), that
    holds a repository directory or one of the root files the classifier names, and a Zig
    `cwd()` read of a variable inside a test, is an error unless `UNANALYSED` names it, with the
    repository paths it stands for (checked like any other read). A literal that names a repository
    file but is a fixture, an argument or message text is in `NOT_READS`, with the reason. Both lists
    are reviewed by hand, and an entry that matches nothing is an error.
  - **The workflow.** `changes` outputs each class as its own value and forces them (above). Every
    job that waits for `changes` (a list of `needs` included) has the job-level
    `if: ${{ !cancelled() }}` (or one of the three exact variants VOPR and the x86_64 macOS job
    need), so a failed `changes` does not skip it (a skipped required check passes). Every step is
    gated in exactly the form `needs.changes.outputs.<class> != 'false'` (optionally after
    `always() && `; VOPR's matrix has its one exact form): no other term is ANDed or ORed in, so no
    `&& false`, `&& matrix.x` or `== 'true'`. The class is one its job depends on
    (`JOB_CLASSES`), the job has a step on its own class, and the steps that run the unit tests are
    gated on exactly `unit` and `macos` (`UNIT_CLASSES`), the classes a file a unit test reads must
    select. `ci-scripts` runs the classifier's own test and its checkout with no `if`. `all` and
    `binary` make each class a job is gated on true. `on.push` has no `paths` or `paths-ignore`.
    packages.yml's jobs have exactly `!cancelled() && (not a draft) && needs.classify.outputs.run
    != 'false'`, parsed, not matched as a substring; its `grep` covers `all`, `binary` and
    `packaging`.
  - **Symbolic links.** A tracked symlink is an error (where the root is a git work tree): the
    guard follows none.
  - **Permissions.** Every workflow that calls another grants it what its jobs ask for (a called
    workflow cannot hold more than its caller; GitHub refuses the file at load, which PR CI cannot
    see for `release.yml`, which runs only on a `VERSION` push).
- ci.yml: the `changes` job outputs every class; each job's steps are gated on its class. The
  classifier's own test, with its checkout, runs on every pull request, ungated. `checks`
  runs `check-code`, `check-scripts` (CI_SCRIPTS_TESTED=1) and `check-packages` as separate steps.
  VOPR's fixed seeds (1, 2, 5) gate on `vopr`; its random seed gates on `any`, so the random search
  still runs on every non-docs change.
- packages.yml (fixes #13): the `paths:` list is gone; a `classify` job runs the classifier and the
  jobs run for `all`, `binary` or `packaging`, or for a change to the plumbing. Its tarball and
  deb/rpm jobs wait for ready_for_review, so they do not run while a pull request is a draft. release.yml grants its call `pull-requests: read`,
  as it does `ci.yml`'s.

## Cross-suite reads found

`tests/api/api.py` is imported by `tests/errors/commands.py` (test:integration), so `tests/api/**`
and `tests/errors/**` select both `api` and `integration`. `demo/**` is read by the seat and canvas
demos. `docs/API.md` by `tests/api/docs_routes.py`; `docs/ERRORS.md` by unit tests (also run
natively by the macOS job) and `ci_test.sh`; `docs/INSTALL.md` by `tests/packaging/repos.py`;
`docs/releases/packages.md`, `.github/scripts/pre_p417_tags` and `ci/install_repo_tools.sh` by the
packaging scripts and their tests (so they select `packaging`); UPSTREAM.md and docs/QUICKSTART.md
by the CI scripts' tests.

## Gaps

What the guard does not see, exactly (each line was checked against `classify_guard.py`); each rests
on the classifier's table and on review:

- **Shell.** Literal repository paths, `$var/x` for a variable the script set from its own
  `dirname "$0"` (or `BASH_SOURCE`), and `$(dirname "$0")/../x` written inline. A path through any
  other variable (`${0%/*}`, an argument, `$PWD`), `eval`, a `cd` and a relative path, or a command
  that reads a directory it was handed, is invisible. Shell inside Python strings and workflow
  `run:` steps is not scanned.
- **Python.** A path with a repository directory in its text that the guard cannot evaluate
  (`f"{self.repo}/docs/x"`, an unknown root joined with `"docs"`) is an error and needs an
  `UNANALYSED` entry; the entry's paths are the reviewer's claim. A path with no repository
  directory in its text (`os.path.join(root, name)` with `name` computed) is not seen, and neither
  is an `importlib.import_module(name)` or `__import__(name)` with a computed name, a `sys.path`
  entry that is not a literal, or a module found through `PYTHONPATH`. A literal naming a directory
  is not expanded into its files. Reads by a subprocess the test starts (a script it runs by a path
  built at run time) are followed only where the path is a literal.
- **Zig.** Only `std.fs.cwd().<read>(...)` and `@embedFile` in `src/**`; a read through another
  handle (`shell.cwd`, a dir opened earlier) is not seen, and a non-literal path outside a `test`
  block is taken for a runtime path.
- **Symbolic links.** A tracked one is refused; one the guard's `git ls-files` cannot see (the root
  is not a git work tree) is not.
- **Reads that are not static.** Anything a suite reads because another file said so (a manifest, a
  glob in a config, `git ls-files`) is invisible. The runtime audit below would close this.
- **Files `all` reaches.** The reads of a file whose class includes `all` are not followed, on the
  reasoning that a change to it runs everything; a change only to a file *it* reads reaches the
  suite only if a suite also reads that file by a path the guard can see.
- **Roots.** A suite that CI runs and that none of the roots names (a new step in a workflow, a
  new function in ci/job.sh) is not seen until its script is a root; ci.yml's job table and
  ci/job.sh's functions are checked, other workflows' steps are not (packages.yml's gate is).
- **Woodpecker.** `docs_only.sh` and `ci/changes.sh` are unchanged, and none of the files read
  `paths-ignore`: removing the Markdown exemption from `ci.yml`'s `push` trigger changes nothing
  for them.

## Cost

A new directory or kind of file is not placed, so it runs everything until a rule is added.
`UNANALYSED` and `NOT_READS` are maintained by hand; a script that builds a repository path in a
new way breaks the guard until an entry says what it reads. Skipped suites are not re-proved on the
pull request: a main push runs everything, so a miss or a flake shows there, not in the merged
change.

## Future work (not decided here)

- Woodpecker uses the same classifier (it still uses `docs_only.sh` and `ci/changes.sh`).
- Cache VOPR results by the binary's hash, so an unchanged binary replays no seed.
- Move random fuzzing and the random VOPR search to cron or the simulation fleet, off the pull
  request path.
- A runtime audit hook: record the files each suite actually opens, and compare them with the
  classifier's table, to catch the reads under Gaps.
