---
id: O14
date: 2026-11-23
area: CI
amends: N68
---

# A pull request skips a class of tests only when a hand-kept manifest says this change cannot reach it

N68 lets a docs-only pull request skip every step. This generalises it: a pull request skips the
steps of a class of tests when the files it changed are, by the manifest `.github/test-inputs.txt`,
none of the files that class reads. Coarse by default: whatever the manifest does not narrow runs
everything.

## The manifest

One file, `.github/test-inputs.txt`, one rule per line: `<class> <glob>`. `classify_changes.sh` reads
its rules from it (the test names another with `CLASSIFY_MANIFEST`).

- A path takes the union of the classes of every rule it matches. In a glob `*` matches any run of
  characters, `/` included, so `tests/api/*` is the whole directory.
- **A path that no rule matches runs everything**, so a new kind of file is safe until someone
  places it. So does a path with an `all` rule.
- `none` says nothing reads the file: Markdown that no test or build step reads.
- **Only two things narrow a pull request:** documentation that no test reads (listed one by one,
  or by a directory of records: `docs/decisions/*`, `worklog/*`, `docs/briefs/*`), and one suite's
  own directory (`tests/api/*`, `tests/views/*`, `tests/release/*`, `demo/*`, `tests/packaging/*`,
  `packaging/*`, the packaging and keychain scripts under `.github/scripts/`, and the like).
- Markdown that a test or build step reads is listed with the classes that read it
  (`docs/API.md` is `api`, `docs/INSTALL.md` is `packaging`, `CHANGELOG.md` is `ci_scripts`), or
  with `all` (`docs/ERRORS.md` and `UPSTREAM.md`: unit tests, the macOS job and the SBOM script read
  them). When in doubt, leave it out: it runs everything.
- Always everything: `src/**`, `build.zig`, `build.zig.zon`, `zig/**`, `VERSION`, `.gitmodules`,
  `.gitattributes`, `ci/**`, `ops/`, `perf/`, `scripts/`, `release/`, `tests/jepsen/`, every other
  workflow script, shared runners and libraries (anything more than one suite uses), and any path
  not listed.
- **The floor is in the classifier, not the manifest.** `.github/workflows/*`, `.github/actions/*`,
  `.github/scripts/classify_*` and `.github/test-inputs.txt` raise every class in
  `classify_changes.sh` itself, whatever the manifest says, so an edit to the manifest, the
  classifier or the wiring cannot narrow the pull request that makes it. `classify_changes_test.sh`
  checks it with a manifest that tries to silence each of them.
- A manifest the classifier cannot read (an unknown class, a rule that is not two fields, no
  rule, no file) is a usage error, exit 2, NRV-E1251; the callers fail closed.

Classes a rule may name: `integration api views release demo demo_r4 demo_r5 macos packaging
ci_scripts mac_keychain`. `unit`, `fuzz`, `vopr` and `targets` have no rule: only `all` selects them.
Derived: `any` (some suite or check class is true: VOPR's random seed runs on it) and `checks`
(`views`, `ci_scripts` or `packaging`).

## What a skip claims

A skip on a pull request claims one thing: **this change cannot have caused a regression in that
class**, because none of the files the manifest says the class reads is in the change (both names
of a rename: the old path is a deletion). It does not claim that the class is green, that it is
deterministic, or that its environment is unchanged. The claim is only as good as the manifest,
whose limits are below.

Everything else runs. Fail closed:

- only a pull request is classified; a push to main (every push, Markdown included: `ci.yml`'s
  `push` trigger has no `paths-ignore`, and the guard checks that), `release.yml`'s `workflow_call`
  and `workflow_dispatch` run everything;
- an unplaced file, an empty list, a list shorter than the pull request's `changed_files`, one at
  the API's 3000-file limit, a `changed_files` that is 0 or missing, a list the API could not
  give, or a list for another head than the run's (the pull request's head is read before and
  after the list and must equal the event's `pull_request.head.sha`) makes `all` true;
- steps are skipped, not jobs, so every required check name keeps reporting (as in N68). A failed
  `changes` job leaves every output empty, and every condition is `!= 'false'`, so everything runs.

## What a skip does not claim

Determinism and a pinned environment are what a *result* needs to vouch for a commit, not what a
skip needs:

- **Nondeterministic classes.** `integration`, `api`, `release`, `demo`, `demo_r4` and `demo_r5` run
  real processes, with wall-clock timeouts and random choices. A green run vouches for its own run
  only; a skipped one vouches for nothing.
- **Classes that depend on their environment.** The runner images roll, `python3` and the packaging
  tools are whatever the image or the pinned installer gives, and `actions/cache@v4` is a moving
  tag. This reaches every class.
- **Never selected by diff.** VOPR's random seed runs on `any`. Random fuzzing, the simulation
  fleet and Jepsen run elsewhere.

Flakes and environment drift are caught by what runs everything: every push to main. A skipped
flake or a drifted image shows on main, not in the merged change, and is then a pre-existing bug
for an issue (CLAUDE.md).

## Mechanism

- `classify_changes.sh` reads file names on stdin and prints one `class=true|false` line per class
  (`--all`; `--expect N`: at least N files, one per line, a rename as `new<TAB>old`, so a rename
  counts once and lists both names; fewer, or an N that is not a positive number, is a cut list).
- `classify_pr.sh` fetches the list once (one line per file: `filename`, then `previous_filename`
  for a rename) and the head before and after it, and hands the list to the classifier with
  `--expect`. It fails closed as above (NRV-E1252) and exits 1 if even `--all` fails. ci.yml's
  `changes` job and packages.yml's `classify` job run it, and nothing else reads the list: the
  floor is the classifier's. packages.yml runs its jobs unless the output says `all=false` and
  `packaging=false`; an empty or garbled output runs them.
- `classify_guard.py` (NRV-E1250), run by `classify_changes_test.sh` in ci.yml's `ci-scripts` job:
  - **The lint.** Every file that a narrowable suite owns (it has a suite class and no `all`) is
    scanned for literal repository paths and Python imports of tracked modules. Each path found
    must carry every one of the file's suite classes, or run everything. A rule that matches no
    file is an error. It is a cheap regex lint, best effort, and no proof (Limits).
  - **The wiring.** `changes` outputs each class as its own value. Every job that waits for
    `changes` has the job-level `if: ${{ !cancelled() }}` (or one of the three exact variants VOPR
    and the x86_64 macOS job need), has no `continue-on-error`, and gates each step in exactly
    `needs.changes.outputs.<class> != 'false'` on a class its job depends on, with no step
    `continue-on-error` either. `system` waits for exactly the jobs it aggregates. The
    classifier's own test and its checkout have no `if`. `on.push` has no `paths` or
    `paths-ignore`. packages.yml's jobs have exactly `!cancelled() && (not a draft) &&
    needs.classify.outputs.run != 'false'`, and no `continue-on-error`. Every workflow that calls
    another grants it what its jobs ask for. A tracked symbolic link is an error.
  - What the steps *do* (the force for the plumbing, the fail-closed reading of empty or garbled
    output, an `--all` that fails, a `changed_files` of 0) is run, not matched:
    `classify_changes_test.sh` runs the `classify` steps of ci.yml and packages.yml as GitHub runs
    them, with a stand-in `gh`.
- ci.yml: each job's steps are gated on its class. `checks` runs `check-code`, `check-scripts` and
  `check-packages` as separate steps. VOPR's fixed seeds (1, 2, 5) gate on `vopr`; its random seed
  gates on `any`.
- packages.yml (fixes #13): the `paths:` list is gone; a `classify` job runs the classifier. Its
  tarball and deb/rpm jobs wait for ready_for_review, so they do not run while a pull request is a
  draft. release.yml grants its call `pull-requests: read`.
- `docs_only.sh` stays Woodpecker's (`ci/changes.sh`). It carries the same list of Markdown that
  tests read (#15), by hand, so Woodpecker no longer calls a read document docs-only.

## Limits

What the manifest and its lint do not see. Each is a way a suite can read a file the manifest does
not say it reads, so a change to that file skips the suite. They are known, not closed:

- **Dynamic paths.** A path built at run time (`os.path.join(root, name)` with a computed `name`,
  an f-string or `+` with a variable, an `importlib` name, `__import__`) is not seen.
- **Directory listings and globs.** `os.listdir`, `glob.glob("tests/api/*.py")`, `ls dir`, `find`
  and a literal that names a directory are not expanded into the files they reach.
- **Imports across suites.** Only `import X` where `X` is a tracked `X.py` (or, with none, a
  tracked package directory by that name) is followed, and not further: a file the imported module
  reads is the module's own entry. `sys.path` and `PYTHONPATH` are not read.
- **Reads through another file.** A manifest, a config, a `git ls-files` or a script the suite
  runs by a computed name.
- **Docstrings and comments** are skipped as mentions, so a docstring that is really read (a
  `__doc__` test) is not seen.
- **Shell variables.** A literal path is found in a shell file; a path assembled from `$var/x` is
  found only by its literal tail, and `$(dirname "$0")/..` is not evaluated.
- **Roots.** The lint scans the files the manifest gives a suite class. A suite file the manifest
  leaves unlisted runs everything, so is safe; one listed under the wrong class is not seen.
- **The wiring of a workflow other than ci.yml and packages.yml** is not checked beyond the
  permissions of a call.
- **Files `all` reaches** are not followed: a change to one runs everything.

Mutants of the guard that stay missed (computed paths, `os.listdir`, `glob`) are tested as limits
in `classify_changes_test.sh` (`limit_*` cases), so a change that starts to see them is noticed.
The real safety net is a runtime audit of which tracked files each suite opens, compared with the
manifest: follow-up #16, not part of this decision. Until it lands, a skipped suite that reads an
unlisted file is found by the next push to main, which runs everything.

## Cost

A new directory or kind of file runs everything until a rule is added, so a narrowing is a
deliberate edit. The manifest is hand-kept: adding a read to a suite's script means adding its
class to the file's rule, which the lint catches for literal paths only. Skipped suites are not
re-proved on the pull request: a main push runs everything, so a miss or a flake shows there, not
in the merged change.

## Future work (not decided here)

- The runtime audit (#16).
- Woodpecker uses the same classifier (it still uses `docs_only.sh` and `ci/changes.sh`).
- Cache VOPR results by the binary's hash, so an unchanged binary replays no seed.
- Move random fuzzing and the random VOPR search to cron or the simulation fleet.
