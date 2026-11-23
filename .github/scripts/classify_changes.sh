#!/usr/bin/env bash
# Reads a pull request's changed files on stdin, one file per line, and prints one `class=true|false`
# line per class: which parts of CI the change can affect (decision O14, which amends N68). A renamed
# file is one line of two names separated by a tab (`new<TAB>old`): the old path is a deletion, and
# both are classified. `--all` prints every class true (a push to main, a release, a dispatch, a
# list that could not be had: the callers fail closed). `--expect N` says how many files the pull
# request changed (`changed_files` of the event); a list of fewer lines (files, not names) than that,
# or as long as the 3000 files the API lists at most, is truncated, and every class is true.
#
# A class may be skipped on a pull request only when this change cannot have caused a regression in
# it: its inputs are known mechanically (the table below, checked against build.zig and tests/** by
# classify_guard.py) and none changed. A skip certifies nothing else: flakes and environment drift
# are caught by pushes to main, which run everything (O14). A file this table does not place makes
# `all` true, and so does an empty list.
#
#   all           every class (CI plumbing every job uses, an unplaced file, an empty list)
#   binary        the inputs of the nerva binary and the Zig tests: every class but mac_keychain
#   any           anything at all changed that something reads: gates what is never skipped by diff
#                 (VOPR's random seed)
#   unit fuzz vopr targets integration api views release demo demo_r4 demo_r5 macos
#                 the suite of that name; its jobs run when the class is true
#   packaging     the Packages workflow (packages.yml)
#   mac_keychain  the macOS signing-keychain job
#   ci_scripts    the CI scripts' own tests (ci/job.sh check-scripts) and what they read
#   checks        the `checks` job: views, ci_scripts or packaging (derived)
#
# `binary` and `all` make the suite classes true, so a job is gated on its own class alone.
#
# Markdown that no build or test reads is placed with no class: a change of only such files makes
# every class false (N68). The Markdown that is read has a rule below, by name; re-check with
# classify_guard.py and: grep -rn '\.md"' build.zig src .github/scripts perf ops scripts ci
set -eu

suites="unit fuzz vopr targets integration api views release demo demo_r4 demo_r5 macos packaging ci_scripts"
all_classes="all binary any $suites mac_keychain checks"

declare -A on=()
for c in $all_classes; do on[$c]=false; done

raise() { local c; for c in "$@"; do on[$c]=true; done; }
raise_all() { raise $all_classes; }

expect=
case "${1:-}" in
--all) raise_all ;;
--expect) expect="${2:-}"; [[ "$expect" =~ ^[0-9]+$ ]] || raise_all ;;
"") ;;
*) echo "error[NRV-E1251]: classify_changes.sh: usage: classify_changes.sh [--all | --expect <changed files>] < files, one per line (a rename: new<TAB>old)" >&2; exit 2 ;;
esac

if [ "${on[all]}" = false ]; then
    entries=0
    files=()
    while IFS= read -r line || [ -n "$line" ]; do
        if [ -n "$line" ]; then
            entries=$((entries + 1))
            IFS=$'\t' read -r -a names <<< "$line"
            files+=("${names[@]}")
        fi
    done
    # An empty list, a list of fewer files than the pull request changed (a rename is one file of
    # two names), or one at the API's limit.
    if [ "$entries" = 0 ] || [ "$entries" -ge 3000 ] || { [ -n "$expect" ] && [ "$entries" -lt "$expect" ]; }; then
        raise_all
    fi
    for file in "${files[@]}"; do
        case "$file" in
        # CI plumbing every job uses, and this classifier and its tests: everything runs.
        .github/workflows/ci.yml | .github/actions/* | ci/job.sh | ci/lib.sh | ci/install_zig.sh | \
            ci/io_uring_check.sh | .github/scripts/classify_*)
            raise all ;;
        # What the nerva binary and every Zig test are built from.
        src/* | build.zig | build.zig.zon | zig/* | VERSION | .gitmodules | .gitattributes | */.gitattributes)
            raise binary ;;
        # Packages: the workflow, its scripts and tests, and what it installs.
        .github/workflows/packages.yml | .github/scripts/package_repos.sh | \
            .github/scripts/repo_install_check.sh | .github/scripts/test_package_repos.py | \
            .github/scripts/r2.py | .github/scripts/test_r2.py | packaging/*)
            raise packaging ci_scripts
            case "$file" in packaging/homebrew/*) raise macos ;; esac ;;
        # Data and tools the packaging scripts read: package_repos.sh reads pre_p417_tags,
        # ci/install_repo_tools.sh installs what test_package_repos.py runs, and
        # docs/releases/packages.md is read by package_repos.sh, r2.py, repo_install_check.sh,
        # their tests and tests/packaging/subkeys.py. Each is also read by the CI scripts' tests.
        .github/scripts/pre_p417_tags | ci/install_repo_tools.sh | docs/releases/packages.md)
            raise packaging ci_scripts ;;
        # tests/packaging/repos.py compares the install text with repo_install_check.sh.
        tests/packaging/* | docs/INSTALL.md) raise packaging ;;
        # The macOS jobs: the smoke test, and the keychain job's scripts.
        tests/macos/*) raise macos ;;
        .github/scripts/mac_* | .github/scripts/test_mac_sign.py) raise mac_keychain ci_scripts ;;
        # What `ci/job.sh check-scripts`, `check-code` and `check-packages` run or read: every
        # other workflow and script, ops/, perf/, the release candidate and the Jepsen harness
        # that ops/jepsen's tests read, and the Markdown they read.
        .github/workflows/* | .github/scripts/* | ci/* | .woodpecker/* | ops/* | perf/* | scripts/* | \
            release/* | tests/jepsen/* | UPSTREAM.md | docs/QUICKSTART.md)
            raise ci_scripts ;;
        # The register of codes: unit tests parse it (the macOS job runs them natively too), and
        # ci_test.sh greps it (N68).
        docs/ERRORS.md) raise unit macos ci_scripts ;;
        # tests/api/docs_routes.py compares it with the routes the gateway serves.
        docs/API.md) raise api ;;
        # tests/api/api.py is imported by tests/errors/commands.py (test:integration), and
        # tests/errors/wire.py runs in test:api: each directory selects both.
        tests/api/* | tests/errors/*) raise api integration ;;
        tests/recover/*) raise integration ;;
        tests/views/*) raise views ;;
        tests/release/*) raise release ;;
        tests/demo/r4.py) raise demo_r4 ;;
        tests/demo/r5.py) raise demo_r5 ;;
        # The seat and canvas demos run demo/*/server.py, which imports demo/*.py.
        tests/demo/* | demo/*) raise demo ;;
        # Markdown that nothing reads: no class.
        *.md) ;;
        *) raise all ;;
        esac
    done
fi

# `all` is every class; `binary` is every class but the keychain job's.
if [ "${on[all]}" = true ]; then raise_all; fi
if [ "${on[binary]}" = true ]; then
    for c in $suites checks; do raise "$c"; done
fi
if [ "${on[views]}" = true ] || [ "${on[ci_scripts]}" = true ] || [ "${on[packaging]}" = true ]; then
    raise checks
fi
for c in $suites mac_keychain checks; do
    if [ "${on[$c]}" = true ]; then raise any; fi
done

for c in $all_classes; do echo "$c=${on[$c]}"; done
