#!/usr/bin/env bash
# Table test for classify_changes.sh, and the guard's own tests (classify_guard.py): the guard
# passes on this repository and fails on a suite that reads a file the classifier does not select
# it for. Decision O14.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
fail=0

suites="unit fuzz vopr targets integration api views release demo demo_r4 demo_r5 macos packaging ci_scripts"
everything="all binary any $suites mac_keychain checks"
# What `binary` makes true: every class but `all` and the keychain job's.
binary_set="binary any $suites checks"

# check "<true classes, space separated>" "<changed files, newline separated>" [classifier args]
check() {
    local want got classes
    want=$(printf '%s\n' $1 | sed '/^$/d' | sort | tr '\n' ' ')
    local files=$2; shift 2
    classes=$(printf '%s' "$files" | "$here/classify_changes.sh" "$@" | sed -n 's/=true$//p' | sort | tr '\n' ' ')
    got=$classes
    if [ "$got" != "$want" ]; then
        echo "classify_changes_test: want [$want], got [$got] for: $(printf '%s' "$files" | head -3) ($*)" >&2
        fail=1
    fi
}

# Every class is printed once, as true or false, in one order.
printed=$(printf 'README.md\n' | "$here/classify_changes.sh" | cut -d= -f1 | tr '\n' ' ')
if [ "$printed" != "$(printf '%s ' $everything)" ]; then
    echo "classify_changes_test: the classes printed are [$printed]" >&2
    fail=1
fi

# Fail closed: an empty list, a list of nothing, and a file nothing places.
check "$everything" ''
check "$everything" $'\n\n'
check "$everything" 'LICENSE'
check "$everything" '.gitignore'
check "$everything" 'notes.md.zig'
check "$everything" 'docs/a.markdown'
check "$everything" 'docs/img.png'
check "$everything" 'newdir/x.py'
check "$everything" 'tests/newsuite/x.py'
check "$everything" $'README.md\nnewdir/x.py'
check "$everything" '.github/CODEOWNERS'
# A list the API cut short: fewer names than the pull request changed, or 3000 or more.
check "$everything" 'README.md' --expect 2
check "$everything" 'README.md' --expect ''
check "$everything" 'README.md' --expect many
check "$everything" 'README.md' --expect
check "" 'README.md' --expect 1
check "$everything" "$(seq 1 3000 | sed 's|^|docs/n|; s|$|.md|')" --expect 3000
check "" "$(seq 1 2999 | sed 's|^|docs/n|; s|$|.md|')" --expect 2999
check "$everything" 'README.md' --all
check "" $'README.md\nworklog/1.md' --expect 2

# Markdown nothing reads: nothing runs (N68).
check "" 'README.md'
check "" $'README.md\ndocs/decisions/O14-x.md\nworklog/14.md\n'
check "" 'docs/briefs/r5.md'
check "" 'CHANGELOG.md'
check "" 'SECURITY.md'
check "" 'docs/INSTALL.md.bak.md'
# Markdown that something reads is a class of its own.
check "unit ci_scripts checks any" 'docs/ERRORS.md'
check "ci_scripts checks any" 'UPSTREAM.md'
check "ci_scripts checks any" 'docs/QUICKSTART.md'
check "ci_scripts checks any" 'docs/releases/packages.md'
check "ci_scripts checks any" 'ops/jepsen/README.md'
check "api any" 'docs/API.md'
check "packaging checks any" 'docs/INSTALL.md'
check "unit ci_scripts checks any" $'README.md\nUPSTREAM.md\ndocs/ERRORS.md'

# The binary's inputs run every suite, but not the keychain job.
for f in src/nerva.zig src/vsr/replica.zig build.zig build.zig.zon zig/download.sh VERSION .gitmodules \
    .gitattributes src/.gitattributes docs/.gitattributes; do
    check "$binary_set" "$f"
done
check "$binary_set" $'README.md\nsrc/nerva.zig'

# CI plumbing and the classifier itself: everything.
for f in ci/job.sh ci/lib.sh ci/install_zig.sh ci/io_uring_check.sh .github/workflows/ci.yml \
    .github/actions/zig-build-cache/action.yml .github/actions/zig-build-cache-save/action.yml \
    .github/scripts/classify_changes.sh .github/scripts/classify_changes_test.sh .github/scripts/classify_guard.py; do
    check "$everything" "$f"
done

# One suite's own files select that suite (and what shares them).
check "api integration any" 'tests/api/api.py'
check "api integration any" 'tests/api/docs_routes.py'
check "api integration any" 'tests/errors/wire.py'
check "api integration any" 'tests/errors/commands.py'
check "integration any" 'tests/recover/recover.py'
check "views checks any" 'tests/views/declared.py'
check "release any" 'tests/release/mixed.py'
check "demo any" 'tests/demo/seats_chaos.py'
check "demo any" 'demo/common.py'
check "demo any" 'demo/seats/index.html'
check "demo_r4 any" 'tests/demo/r4.py'
check "demo_r5 any" 'tests/demo/r5.py'
check "macos any" 'tests/macos/smoke.py'
check "packaging checks any" 'tests/packaging/install.py'
check "packaging ci_scripts macos checks any" 'packaging/homebrew/nerva.rb'
check "packaging ci_scripts checks any" 'packaging/linux/install.sh'
check "packaging ci_scripts checks any" '.github/workflows/packages.yml'
check "packaging ci_scripts checks any" '.github/scripts/package_repos.sh'
check "packaging ci_scripts checks any" '.github/scripts/r2.py'
check "mac_keychain ci_scripts checks any" '.github/scripts/mac_keychain.sh'
check "mac_keychain ci_scripts checks any" '.github/scripts/test_mac_sign.py'
for f in .github/scripts/sbom.py .github/scripts/docs_only.sh .github/scripts/release_check.sh \
    .github/workflows/release.yml .github/workflows/jepsen.yml ci/ci_test.sh ci/woodpecker_step.sh \
    ci/cache.sh ci/changes.sh .woodpecker/api.yaml ops/ci/README.md ops/jepsen/jepsen_report.py \
    perf/nightly/compare.py scripts/quickstart_loop.sh release/candidate tests/jepsen/run.sh; do
    check "ci_scripts checks any" "$f"
done
# Unions.
check "api integration release any" $'tests/api/a.py\ntests/release/b.py'
check "views checks any" $'README.md\ntests/views/x.py'
check "demo demo_r4 any" $'demo/common.py\ntests/demo/r4.py'

# The guard passes on this repository.
if ! python3 -I "$here/classify_guard.py" --root "$root" > /dev/null 2> "${TMPDIR:-/tmp}/classify_guard.$$.err"; then
    echo "classify_changes_test: the guard fails on this repository:" >&2
    cat "${TMPDIR:-/tmp}/classify_guard.$$.err" >&2
    fail=1
fi
rm -f "${TMPDIR:-/tmp}/classify_guard.$$.err"

# The guard on a small tree: a suite that reads a file the classifier does not select it for fails,
# and each way of reading one is seen.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
tree() { # tree <name>: a repository with one api script, which does `reads`
    local t="$tmp/$1"
    mkdir -p "$t/tests/api" "$t/tests/shared" "$t/demo" "$t/src" "$t/docs"
    cat > "$t/build.zig" <<'ZIG'
pub fn build() void {
    for ([_][]const u8{ "a.py" }) |script| {
        const run = b.addSystemCommand(&.{ "python3", b.fmt("tests/api/{s}", .{script}) });
        steps.test_api.dependOn(&run.step);
    }
}
ZIG
    echo "x" > "$t/demo/x.py"; echo x > "$t/src/x.zig"; echo x > "$t/docs/API.md"; echo x > "$t/docs/ERRORS.md"
    printf 'def f():\n    pass\n' > "$t/demo/helper.py"
    printf 'def f():\n    pass\n' > "$t/tests/api/own.py"
    printf '%s\n' "$2" > "$t/tests/api/a.py"
}
guard_says() { # guard_says <want exit> <name> <script body> <fragment>
    tree "$2" "$3"
    local out status=0
    out=$(python3 -I "$here/classify_guard.py" --root "$tmp/$2" 2>&1) || status=$?
    if [ "$status" != "$1" ]; then
        echo "classify_changes_test: guard on '$2': exit $status, want $1: $out" >&2
        fail=1
    elif [ -n "${4:-}" ] && ! printf "%s" "$out" | grep -qF -- "${4:-}"; then
        echo "classify_changes_test: guard on '$2' does not say '${4:-}': $out" >&2
        fail=1
    fi
}
guard_says 0 own 'import os
import own'
guard_says 0 binary 'x = "src/x.zig"'
guard_says 0 api_doc 'x = "docs/API.md"'
guard_says 0 unplaced 'import os
open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "shared", "data.txt"))'
guard_says 1 literal 'x = "docs/ERRORS.md"' 'docs/ERRORS.md is read by the api suite'
guard_says 1 joined 'import os
HERE = os.path.dirname(os.path.abspath(__file__))
open(os.path.join(HERE, "..", "..", "demo", "x.py"))' 'demo/x.py is read by the api suite'
guard_says 1 pathlib 'from pathlib import Path
open(Path(__file__).resolve().parents[2] / "demo/x.py")' 'demo/x.py is read by the api suite'
guard_says 1 sys_path 'import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "demo"))
import helper' 'demo/helper.py is read by the api suite'
guard_says 1 chained 'import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "demo"))
import helper' 'tests/api/a.py'
# A step the guard does not know, and a script build.zig runs that is not there.
tree unknown_step 'x = 1'
sed -i 's/steps.test_api/steps.test_mystery/' "$tmp/unknown_step/build.zig"
if python3 -I "$here/classify_guard.py" --root "$tmp/unknown_step" > /dev/null 2>&1; then
    echo "classify_changes_test: the guard accepted a step it does not know" >&2
    fail=1
fi
tree missing 'x = 1'
rm "$tmp/missing/tests/api/a.py"
if python3 -I "$here/classify_guard.py" --root "$tmp/missing" > /dev/null 2>&1; then
    echo "classify_changes_test: the guard accepted a script that is not there" >&2
    fail=1
fi

[ "$fail" = 0 ] && echo "classify_changes_test: ok"
exit "$fail"
