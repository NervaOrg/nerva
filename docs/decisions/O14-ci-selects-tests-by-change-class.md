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

- only a pull request is classified; a push to main, `release.yml`'s `workflow_call` and
  `workflow_dispatch` run everything;
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
  line per class (`--all`, `--expect N`: a list at least as long as N, since a rename lists two
  names). Classes: `all`, `binary` (src/, build.zig, zig/, VERSION: every suite but the keychain
  job), `any`, one per suite (`unit fuzz vopr targets integration api views release demo demo_r4
  demo_r5 macos packaging ci_scripts`), `mac_keychain` and the derived `checks`. `all` and `binary`
  fold into the suites, so a job gates on its own class alone. `docs_only.sh` stays as it is:
  Woodpecker's `ci/changes.sh` uses it.
- `.github/scripts/classify_pr.sh` fetches the list (`filename` and `previous_filename` of each file)
  and the head, and fails closed as above. ci.yml's `changes` job and packages.yml's `classify` job
  run it.
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
  - **What it cannot evaluate fails closed.** A path built from parts the guard cannot evaluate, that
    holds a repository directory or one of the root files the classifier names, and a Zig
    `cwd()` read of a variable inside a test, is an error unless `UNANALYSED` names it, with the
    repository paths it stands for (checked like any other read). A literal that names a repository
    file but is a fixture, an argument or message text is in `NOT_READS`, with the reason. Both lists
    are reviewed by hand, and an entry that matches nothing is an error.
  - **The workflow.** `changes` outputs each class as its own value; every step of a job that waits
    for `changes` (a list of `needs` included) is gated, in the form `!= 'false'` that runs when
    `changes` fails, on a class its job depends on (`JOB_CLASSES`), and the job has a step on its
    own class; `all` and `binary` make each class a job is gated on true.
  - **Permissions.** Every workflow that calls another grants it what its jobs ask for (a called
    workflow cannot hold more than its caller; GitHub refuses the file at load, which PR CI cannot
    see for `release.yml`, which runs only on a `VERSION` push).
- ci.yml: the `changes` job outputs every class; each job's steps are gated on its class. `checks`
  runs `check-code`, `check-scripts` (CI_SCRIPTS_TESTED=1) and `check-packages` as separate steps.
  VOPR's fixed seeds (1, 2, 5) gate on `vopr`; its random seed gates on `any`, so the random search
  still runs on every non-docs change.
- packages.yml (fixes #13): the `paths:` list is gone; a `classify` job runs the classifier and the
  jobs run for `all`, `binary` or `packaging`. release.yml grants its call `pull-requests: read`,
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

What the guard does not see, exactly; each rests on the classifier's table and on review:

- **Shell.** Only literal repository paths and `$var/x` for a variable the script set from its own
  `dirname "$0"`. A path through any other variable, `eval`, a `cd` and a relative path, or a
  command that reads a directory it was handed, is invisible. Shell inside Python strings and
  workflow `run:` steps is not scanned.
- **Python.** A path through a function argument or an attribute (`f"{self.repo}/docs/x"`) is not
  evaluated; it is an error when it holds a repository directory, so it needs an `UNANALYSED` entry,
  and the entry's paths are the reviewer's claim. A path with no repository directory in its text
  (`os.path.join(root, name)` with `name` computed) is not seen. A literal naming a directory is
  not expanded into its files. Reads by a subprocess the test starts (a script it runs by a path
  built at run time) are followed only where the path is a literal.
- **Zig.** Only `std.fs.cwd().<read>(...)` and `@embedFile` in `src/**`; a read through another
  handle (`shell.cwd`, a dir opened earlier) is not seen, and a non-literal path outside a `test`
  block is taken for a runtime path.
- **Reads that are not static.** Anything a suite reads because another file said so (a manifest, a
  glob in a config, `git ls-files`) is invisible. The runtime audit below would close this.
- **Files `all` reaches.** The reads of a file whose class includes `all` are not followed, on the
  reasoning that a change to it runs everything; a change only to a file *it* reads reaches the
  suite only if a suite also reads that file by a path the guard can see.
- **Roots.** A suite that CI runs and that none of the roots names (a new step in a workflow, a
  new function in ci/job.sh) is not seen until its script is a root; ci.yml's job table and
  ci/job.sh's functions are checked, other workflows' steps are not.

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
