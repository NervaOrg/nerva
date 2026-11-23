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
check "unit macos ci_scripts checks any" 'docs/ERRORS.md'
check "ci_scripts checks any" 'UPSTREAM.md'
check "ci_scripts checks any" 'docs/QUICKSTART.md'
check "packaging ci_scripts checks any" 'docs/releases/packages.md'
check "ci_scripts checks any" 'ops/jepsen/README.md'
check "api any" 'docs/API.md'
check "packaging checks any" 'docs/INSTALL.md'
check "unit macos ci_scripts checks any" $'README.md\nUPSTREAM.md\ndocs/ERRORS.md'

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
# What package_repos.sh and test_package_repos.py read and run: data and the tool installer.
check "packaging ci_scripts checks any" '.github/scripts/pre_p417_tags'
check "packaging ci_scripts checks any" 'ci/install_repo_tools.sh'
check "packaging ci_scripts checks any" '.github/scripts/test_package_repos.py'
check "packaging ci_scripts checks any" 'packaging/keys/nerva-release.asc'
check "mac_keychain ci_scripts checks any" '.github/scripts/mac_keychain.sh'
check "mac_keychain ci_scripts checks any" '.github/scripts/test_mac_sign.py'
for f in .github/scripts/sbom.py .github/scripts/docs_only.sh .github/scripts/release_check.sh \
    .github/workflows/release.yml .github/workflows/jepsen.yml ci/ci_test.sh ci/woodpecker_step.sh \
    ci/cache.sh ci/changes.sh .woodpecker/api.yaml ops/ci/README.md ops/jepsen/jepsen_report.py \
    perf/nightly/compare.py scripts/quickstart_loop.sh release/candidate tests/jepsen/run.sh; do
    check "ci_scripts checks any" "$f"
done
# A rename lists both names (the API's `filename` and `previous_filename`): the old path is a
# deletion, and the new one may be Markdown or unplaced. Each class is selected by its old path.
# The new name alone selects nothing, which is the bug a list without previous_filename had.
check "" 'notes/x.md' --expect 1
check "unit macos ci_scripts checks any" $'notes/x.md\tdocs/ERRORS.md' --expect 1
check "unit macos ci_scripts checks any" $'docs/ERRORS-old.md\tdocs/ERRORS.md' --expect 1
check "api any" $'docs/HTTP.md\tdocs/API.md' --expect 1
check "$binary_set" $'notes/wire_code.md\tsrc/nerva/wire_code.zig' --expect 1
check "api integration any" $'docs/api.md\ttests/api/api.py' --expect 1
check "packaging checks any" $'docs/old.md\tdocs/INSTALL.md' --expect 1
check "packaging ci_scripts checks any" $'docs/old.md\tdocs/releases/packages.md' --expect 1
check "ci_scripts checks any" $'docs/old.md\tUPSTREAM.md' --expect 1
check "views checks any" $'notes/x.md\ttests/views/declared.py' --expect 1
check "release any" $'notes/x.md\ttests/release/mixed.py' --expect 1
check "demo any" $'notes/x.md\tdemo/common.py' --expect 1
check "packaging ci_scripts checks any" $'notes/x.md\t.github/scripts/pre_p417_tags' --expect 1
# --expect counts files, one line each (a rename is one file of two names), not names: a list with
# a rename that is missing a file is truncated, though it has as many names as the files changed.
# (review 6031181952: {rename views/old -> views/new, README.md} against 3 files, src/x.zig missing.)
check "$everything" $'tests/views/new.py\ttests/views/old.py\nREADME.md' --expect 3
check "$binary_set" $'tests/views/new.py\ttests/views/old.py\nREADME.md\nsrc/x.zig' --expect 3
check "views checks any" $'tests/views/new.py\ttests/views/old.py\nREADME.md\nnotes/x.md' --expect 3
check "$everything" $'a.md\tb.md\tc.md' --expect 2
check "" $'a.md\tb.md\nc.md' --expect 2
# A list with more files than changed_files is whole; one with fewer is truncated.
check "unit macos ci_scripts checks any" $'a.md\tdocs/ERRORS.md\nb.md\nREADME.md' --expect 3
check "unit macos ci_scripts checks any" $'a.md\tdocs/ERRORS.md\nb.md' --expect 2
check "$everything" $'a.md\nREADME.md' --expect 3
check "$everything" $'a.md\tREADME.md' --expect 2
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
guard_in() { # guard_in <want exit> <name> [fragment]: the guard on a tree already built
    local out status=0
    out=$(python3 -I "$here/classify_guard.py" --root "$tmp/$2" 2>&1) || status=$?
    if [ "$status" != "$1" ]; then
        echo "classify_changes_test: guard on '$2': exit $status, want $1: $out" >&2
        fail=1
    elif [ -n "${3:-}" ] && ! printf "%s" "$out" | grep -qF -- "$3"; then
        echo "classify_changes_test: guard on '$2' does not say '$3': $out" >&2
        fail=1
    elif [ "$1" = 1 ] && ! printf "%s" "$out" | grep -qF 'NRV-E1250'; then
        echo "classify_changes_test: guard on '$2' fails without NRV-E1250: $out" >&2
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
# Path construction the guard evaluates: f-strings and `+`, beside os.path.join and pathlib.
guard_says 1 fstring 'import os
open(f"{os.path.dirname(os.path.abspath(__file__))}/../../docs/ERRORS.md")' 'docs/ERRORS.md is read by the api suite'
guard_says 1 concat 'import os
open(os.path.dirname(os.path.abspath(__file__)) + "/../../docs/ERRORS.md")' 'docs/ERRORS.md is read by the api suite'
guard_says 0 fstring_placed 'import os
open(f"{os.path.dirname(os.path.abspath(__file__))}/../../docs/API.md")'
# Path construction it cannot evaluate fails closed, unless a reviewed entry says what it reads.
guard_says 1 opaque 'import tempfile
open(f"{tempfile.gettempdir()}/docs/x.md")' 'cannot evaluate'
guard_says 1 opaque_join 'import os, tempfile
open(os.path.join(tempfile.gettempdir(), "docs/x.md"))' 'cannot evaluate'
guard_says 1 opaque_format 'import tempfile
open("{}/ci/job.sh".format(tempfile.gettempdir()))' 'cannot evaluate'
guard_says 0 opaque_message 'import sys
print(f"see docs/x.md for {sys.argv}")'
guard_says 0 opaque_raise 'raise SystemExit(f"see docs/x.md for {1 + 1}")'
# A join whose root it cannot place, with a repository directory in it, fails closed (the second review).
guard_says 1 unknown_root_join 'import os, sys
open(os.path.join(sys.argv[1], "docs", "API.md"))' 'cannot evaluate'
guard_says 1 unknown_root_pathlib 'import sys
from pathlib import Path
open(Path(sys.argv[1]) / "docs" / "API.md")' 'cannot evaluate'
guard_says 0 unknown_root_other 'import os, sys
open(os.path.join(sys.argv[1], "scratch", "x"))'
# A renamed import is the module it renames.
guard_says 1 alias_join 'import os as _o, sys as _s
open(_o.path.join(_s.argv[1], "docs", "API.md"))' 'cannot evaluate'
guard_says 1 alias_path 'import sys as _s
from pathlib import Path as _P
open(_P(__file__).resolve().parents[2] / "docs/ERRORS.md")' 'docs/ERRORS.md is read by the api suite'
guard_says 1 alias_sys_path 'import sys as _s
_s.path.insert(0, "demo")
import helper' 'demo/helper.py is read by the api suite'
guard_says 1 from_join 'from os.path import join, dirname, abspath
open(join(dirname(abspath(__file__)), "..", "..", "docs", "ERRORS.md"))' 'docs/ERRORS.md is read by the api suite'
# A read inside print, assert or raise is still a read; only the message text is exempt.
guard_says 1 print_open 'print(open("docs/ERRORS.md").read())' 'docs/ERRORS.md is read by the api suite'
guard_says 1 assert_open 'assert open("docs/ERRORS.md").read()' 'docs/ERRORS.md is read by the api suite'
guard_says 1 raise_open 'raise SystemExit(open("docs/ERRORS.md").read())' 'docs/ERRORS.md is read by the api suite'
# A relative sys.path entry, and a module imported by name.
guard_says 1 sys_path_relative 'import sys
sys.path.insert(0, "demo")
import helper' 'demo/helper.py is read by the api suite'
guard_says 1 import_module 'import sys, importlib
sys.path.insert(0, "demo")
importlib.import_module("helper")' 'demo/helper.py is read by the api suite'
guard_says 1 dunder_import 'import sys
sys.path.append("demo")
__import__("helper")' 'demo/helper.py is read by the api suite'
# A tracked symbolic link, in a tree that is a git work tree.
tree symlink 'x = 1'
ln -s ../../docs/API.md "$tmp/symlink/tests/api/link.md"
git -C "$tmp/symlink" init -q
git -C "$tmp/symlink" add -f -A
guard_in 1 symlink 'is a symbolic link'

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

# Shell roots: the scripts ci/job.sh's functions run are read for the repository paths in them.
shell_tree() { # shell_tree <name> <body of scripts/t.sh>
    tree "$1" 'x = 1'
    mkdir -p "$tmp/$1/ci" "$tmp/$1/scripts"
    cat > "$tmp/$1/ci/job.sh" <<'SH'
check_code() {
    .github/scripts/docs_only_test.sh
}
check_scripts() {
    scripts/t.sh
}
check_packages() {
    python3 .github/scripts/test_package_repos.py
}
SH
    mkdir -p "$tmp/$1/.github/scripts"
    touch "$tmp/$1/.github/scripts/docs_only_test.sh" "$tmp/$1/.github/scripts/test_package_repos.py"
    printf '%s\n' "$2" > "$tmp/$1/scripts/t.sh"
}
shell_tree sh_ok 'cat docs/ERRORS.md'
guard_in 0 sh_ok
shell_tree sh_api 'cat "$here/../docs/API.md"
here=$(cd "$(dirname "$0")" && pwd)'
guard_in 1 sh_api 'docs/API.md is read by the ci_scripts suite'
shell_tree sh_literal 'grep -q x docs/API.md'
guard_in 1 sh_literal 'docs/API.md is read by the ci_scripts suite'
shell_tree sh_root 'root=$(cd "$(dirname "$0")/.." && pwd)
cat "$root/docs/API.md"'
guard_in 1 sh_root 'docs/API.md is read by the ci_scripts suite'
shell_tree sh_comment '# docs/API.md is not read
echo hi'
guard_in 0 sh_comment
shell_tree sh_dirname 'cat "$(dirname "$0")/../docs/API.md"'
guard_in 1 sh_dirname 'docs/API.md is read by the ci_scripts suite'
shell_tree sh_bash_source 'cat "$(dirname "${BASH_SOURCE[0]}")/../docs/API.md"'
guard_in 1 sh_bash_source 'docs/API.md is read by the ci_scripts suite'

# The unit tests' reads of files outside src/: a literal, a const, an embed, a path it cannot evaluate.
zig_tree() { # zig_tree <name> <zig source>
    tree "$1" 'x = 1'
    printf '%s\n' "$2" > "$tmp/$1/src/x.zig"
}
zig_tree zig_ok 'test "x" { _ = try std.fs.cwd().readFileAlloc(a, "docs/ERRORS.md", 1); }'
guard_in 0 zig_ok
zig_tree zig_literal 'test "x" { _ = try std.fs.cwd().readFileAlloc(a, "docs/API.md", 1); }'
guard_in 1 zig_literal 'docs/API.md in a unit test'
zig_tree zig_const 'const path = "docs/API.md";
test "x" { _ = try std.fs.cwd().readFileAlloc(a, path, 1); }'
guard_in 1 zig_const 'docs/API.md in a unit test'
zig_tree zig_embed 'const text = @embedFile("../docs/API.md");'
guard_in 1 zig_embed 'embeds docs/API.md'
zig_tree zig_opaque 'test "x" { const p = try std.fmt.allocPrint(a, "{s}", .{name}); _ = try std.fs.cwd().readFileAlloc(a, p, 1); }'
guard_in 1 zig_opaque 'cannot evaluate in a unit test'
zig_tree zig_runtime 'fn f() void { _ = try std.fs.cwd().readFileAlloc(a, path, 1); }'
guard_in 0 zig_runtime

# ci.yml: each way the guard says a gate is wrong. A job that waits for `changes`, with its steps.
# The classify step of the `changes` job: it forces every class for a change to the workflows, the
# classifier or the actions, from the pull request's own file list (the guard reads these fragments).
force_step='      - id: classify
        run: |
          if [ "$EVENT" = pull_request ]; then
            gh api x --jq ".[] | .filename, (.previous_filename // empty)" | grep -Eq "^(.github/workflows/|.github/scripts/classify_|.github/actions/)"
          fi'
workflow_tree() { # workflow_tree <name> <outputs override sed> <job yaml>
    tree "$1" 'x = 1'
    mkdir -p "$tmp/$1/.github/workflows"
    {
        printf 'on: push\njobs:\n  changes:\n    runs-on: x\n    outputs:\n'
        for c in $everything; do printf '      %s: ${{ steps.classify.outputs.%s }}\n' "$c" "$c"; done
        printf '    steps:\n%s\n%s\n' "$force_step" "$3"
    } > "$tmp/$1/.github/workflows/ci.yml"
    if [ -n "$2" ]; then sed -i "$2" "$tmp/$1/.github/workflows/ci.yml"; fi
}
job() { # job <name> <needs> <condition>: a job of two steps gated on <condition>
    printf '  %s:
    needs: %s
    if: ${{ !cancelled() }}
    runs-on: x
    steps:
      - run: a
        if: %s
      - run: b
        if: %s
' "$1" "$2" "$3" "$3"
}
ok="needs.changes.outputs.unit != 'false'"
workflow_tree wf_ok '' "$(job unit changes "$ok")"
guard_in 0 wf_ok
workflow_tree wf_missing_output '/      demo_r4:/d' "$(job unit changes "$ok")"
guard_in 1 wf_missing_output 'does not output the class demo_r4'
workflow_tree wf_swapped_output 's/      views: .*/      views: ${{ steps.classify.outputs.api }}/' "$(job unit changes "$ok")"
guard_in 1 wf_swapped_output 'outputs views as'
workflow_tree wf_unknown_class '' "$(job unit changes "needs.changes.outputs.unitt != 'false'")"
guard_in 1 wf_unknown_class 'which is not a class'
workflow_tree wf_wrong_gate '' "$(job unit changes "needs.changes.outputs.fuzz != 'false'")"
guard_in 1 wf_wrong_gate 'is gated on `fuzz`, but the job depends on unit'
workflow_tree wf_fail_open '' "$(job unit changes "needs.changes.outputs.unit == 'true'")"
guard_in 1 wf_fail_open 'must be exactly'
workflow_tree wf_or_true '' "$(job unit changes "needs.changes.outputs.unit != 'false' || true")"
guard_in 1 wf_or_true 'must be exactly'
workflow_tree wf_ungated '' "$(job unit changes "$ok")
      - run: c"
guard_in 1 wf_ungated 'no condition on `changes`'
# A list of needs is read, not skipped.
workflow_tree wf_list_needs '' "$(job unit '[changes, other]' "$ok")
  other:
    runs-on: x
    steps: []"
guard_in 0 wf_list_needs
workflow_tree wf_list_needs_wrong '' "$(job unit '[changes, other]' "needs.changes.outputs.fuzz != 'false'")"
guard_in 1 wf_list_needs_wrong 'depends on unit'
workflow_tree wf_unknown_job '' "$(job mystery changes "$ok")"
guard_in 1 wf_unknown_job 'does not know which class gates it'
workflow_tree wf_no_primary '' "$(job unit changes "needs.changes.outputs.any != 'false'")"
guard_in 1 wf_no_primary 'is gated on `any`'

# The classifier must not decide whether its own test runs (the second review's selfgate mutant): a
# change to the workflows or the classifier forces every class, and the classifier's test and its
# checkout have no `if`.
workflow_tree wf_no_force 's/previous_filename/other/' "$(job unit changes "$ok")"
guard_in 1 wf_no_force 'does not force every class'
workflow_tree wf_no_force_path 's|\.github/actions/|.github/action/|' "$(job unit changes "$ok")"
guard_in 1 wf_no_force_path 'does not force every class'
workflow_tree wf_no_job_if '/    if: \${{ !cancelled() }}/d' "$(job unit changes "$ok")"
guard_in 1 wf_no_job_if 'job unit has `if: (none)`'
workflow_tree wf_job_if_output 's/if: \${{ !cancelled() }}/if: ${{ needs.changes.outputs.unit == '"'true'"' }}/' "$(job unit changes "$ok")"
guard_in 1 wf_job_if_output 'job unit has `if: needs.changes.outputs.unit'
workflow_tree wf_job_if_always 's/if: \${{ !cancelled() }}/if: ${{ always() }}/' "$(job unit changes "$ok")"
guard_in 1 wf_job_if_always 'job unit has `if: always()`'
# A class gate is never ANDed with another term, nor joined by `||`.
workflow_tree wf_and_false '' "$(job unit changes "needs.changes.outputs.unit != 'false' && false")"
guard_in 1 wf_and_false 'must be exactly'
workflow_tree wf_and_matrix '' "$(job unit changes "needs.changes.outputs.unit != 'false' && matrix.x == 'y'")"
guard_in 1 wf_and_matrix 'must be exactly'
workflow_tree wf_always_ok '' "$(job unit changes "always() && needs.changes.outputs.unit != 'false'")"
guard_in 0 wf_always_ok
workflow_tree wf_always_or '' "$(job unit changes "always() || needs.changes.outputs.unit != 'false'")"
guard_in 1 wf_always_or 'must be exactly'
# The steps that run the unit tests are gated on the classes a file a unit test reads must select.
unit_steps() { # unit_steps <class of the step that runs the unit tests>
    printf '  unit:
    needs: changes
    if: ${{ !cancelled() }}
    runs-on: x
    steps:
      - run: ci/job.sh unit
        if: needs.changes.outputs.%s != '"'false'"'
' "$1"
}
workflow_tree wf_unit_steps '' "$(unit_steps unit)"
guard_in 1 wf_unit_steps 'requires a file a unit test reads to select'
# The classifier's own test and its checkout run on every pull request.
ci_scripts_job() { # ci_scripts_job <checkout if line> <test if line>
    printf '  ci-scripts:
    needs: changes
    if: ${{ !cancelled() }}
    runs-on: x
    steps:
      - uses: actions/checkout@x
%s
      - run: .github/scripts/classify_changes_test.sh
%s
      - run: ci/ci_test.sh
        if: needs.changes.outputs.ci_scripts != '"'false'"'
' "$1" "$2"
}
workflow_tree wf_cs_ok '' "$(ci_scripts_job '        name: c' '        name: t')"
guard_in 0 wf_cs_ok
workflow_tree wf_cs_test_gated '' "$(ci_scripts_job '        name: c' "        if: needs.changes.outputs.any != 'false'")"
guard_in 1 wf_cs_test_gated 'with no gate'
workflow_tree wf_cs_checkout_gated '' "$(ci_scripts_job "        if: needs.changes.outputs.any != 'false'" '        name: t')"
guard_in 1 wf_cs_checkout_gated 'with no gate'
workflow_tree wf_cs_no_test '' "$(ci_scripts_job '        name: c' '        name: t' | sed 's|classify_changes_test.sh|other.sh|')"
guard_in 1 wf_cs_no_test 'has no step that runs classify_changes_test.sh'
# Every push to main runs everything: a `paths-ignore` on `push` skips what a pull request skipped.
workflow_tree wf_push_ignore 's/^on: push/on:\n  push:\n    paths-ignore: ["**.md"]/' "$(job unit changes "$ok")"
guard_in 1 wf_push_ignore '`on.push` has `paths` or `paths-ignore`'
workflow_tree wf_push_paths 's/^on: push/on:\n  push:\n    paths: ["src\/**"]/' "$(job unit changes "$ok")"
guard_in 1 wf_push_paths '`on.push` has `paths` or `paths-ignore`'
workflow_tree wf_push_branches 's/^on: push/on:\n  push:\n    branches: [main]/' "$(job unit changes "$ok")"
guard_in 0 wf_push_branches

# packages.yml: the jobs wait for `classify`, run when it fails, and `run` covers every class.
packages_tree() { # packages_tree <name> <sed over packages.yml>
    workflow_tree "$1" '' "$(job unit changes "$ok")"
    cat > "$tmp/$1/.github/workflows/packages.yml" <<'YML'
on: push
jobs:
  classify:
    runs-on: x
    steps:
      - id: classify
        run: |
          classes=$(mktemp)
          if grep -qx -e all=true -e binary=true -e packaging=true "$classes"; then run=true; else run=false; fi
          if [ "$EVENT" = pull_request ]; then
            gh api x --jq '.[] | .filename, (.previous_filename // empty)' | grep -Eq '^(.github/workflows/|.github/scripts/classify_|.github/actions/)'
          fi
  tarball:
    needs: classify
    if: ${{ !cancelled() && (github.event_name != 'pull_request' || !github.event.pull_request.draft) && needs.classify.outputs.run != 'false' }}
    runs-on: x
    steps: []
YML
    if [ -n "$2" ]; then sed -i "$2" "$tmp/$1/.github/workflows/packages.yml"; fi
}
packages_tree pk_ok ''
guard_in 0 pk_ok
packages_tree pk_no_cancelled 's/!cancelled() && //'
guard_in 1 pk_no_cancelled 'job `tarball` waits for `classify`'
packages_tree pk_cancelled_substring 's/!cancelled() && /!cancelled() || /'
guard_in 1 pk_cancelled_substring 'job `tarball` waits for `classify`'
packages_tree pk_always_false "s/needs.classify.outputs.run != 'false' }}/needs.classify.outputs.run != 'false' \&\& false }}/"
guard_in 1 pk_always_false 'job `tarball` waits for `classify`'
packages_tree pk_equals_true "s/needs.classify.outputs.run != 'false'/needs.classify.outputs.run == 'true'/"
guard_in 1 pk_equals_true 'job `tarball` waits for `classify`'
packages_tree pk_grep_misses 's/ -e packaging=true//'
guard_in 1 pk_grep_misses '`classify` runs the jobs for the classes'
packages_tree pk_grep_extra 's/ -e packaging=true/ -e packaging=true -e demo=true/'
guard_in 1 pk_grep_extra '`classify` runs the jobs for the classes'
packages_tree pk_no_force 's/previous_filename/other/'
guard_in 1 pk_no_force 'does not force the run'

# A workflow that calls another grants it what its jobs ask for (the next release failed at startup
# when release.yml called packages.yml without pull-requests: read).
call_tree() { # call_tree <name> <caller permissions yaml, indented 4> <callee job permissions yaml, indented 4>
    tree "$1" 'x = 1'
    mkdir -p "$tmp/$1/.github/workflows"
    printf 'on: push\njobs:\n  call:\n    uses: ./.github/workflows/callee.yml\n%s\n' "$2" > "$tmp/$1/.github/workflows/caller.yml"
    printf 'on: workflow_call\npermissions:\n  contents: read\njobs:\n  job:\n    runs-on: x\n%s\n    steps: []\n' "$3" > "$tmp/$1/.github/workflows/callee.yml"
}
call_tree call_ok '    permissions:
      contents: read
      pull-requests: read' '    permissions:
      contents: read
      pull-requests: read'
guard_in 0 call_ok
call_tree call_short '    permissions:
      contents: read' '    permissions:
      contents: read
      pull-requests: read'
guard_in 1 call_short 'asks for `pull-requests: read`'
call_tree call_none '' '    permissions:
      contents: read
      issues: write'
guard_in 1 call_none 'asks for `issues: write`'
call_tree call_downgrade '    permissions:
      contents: read
      issues: read' '    permissions:
      issues: write'
guard_in 1 call_downgrade 'asks for `issues: write`'
call_tree call_write_covers '    permissions:
      contents: write
      issues: write' '    permissions:
      issues: write'
guard_in 0 call_write_covers
call_tree call_nothing_asked '    permissions:
      contents: read' ''
guard_in 0 call_nothing_asked

# classify_pr.sh, with a stand-in `gh`: renames bring both names, a head that moved fails closed.
stub="$tmp/stub"
mkdir -p "$stub"
cat > "$stub/gh" <<'SH'
#!/usr/bin/env bash
# gh api <endpoint> [--paginate] --jq <program>; the fixtures are in STUB_DIR.
endpoint=$2; program=
for ((i = 3; i < $#; i++)); do if [ "${!i}" = --jq ]; then j=$((i + 1)); program=${!j}; fi; done
case $endpoint in
*/files)
    [ -z "${STUB_FILES_FAIL:-}" ] || exit 1
    jq -r "$program" "$STUB_DIR/files.json" ;;
*)
    n=$(cat "$STUB_DIR/n" 2> /dev/null || echo 0); echo $((n + 1)) > "$STUB_DIR/n"
    sha=$(sed -n "$((n + 1))p" "$STUB_DIR/heads")
    [ -n "$sha" ] || exit 1
    printf '{"head":{"sha":"%s"}}' "$sha" | jq -r "$program" ;;
esac
SH
chmod +x "$stub/gh"
# pr_says "<true classes>" '<files json>' '<heads, one per API call>' [env VAR=value ...]
pr_says() {
    local want=$1 files=$2 heads=$3 got
    shift 3
    rm -f "$stub/n"
    printf '%s' "$files" > "$stub/files.json"
    printf '%s\n' $heads > "$stub/heads"
    got=$(env PATH="$stub:$PATH" STUB_DIR="$stub" EVENT=pull_request PR=7 HEAD_SHA=aaa CHANGED=1 REPO=o/r "$@" \
        "$here/classify_pr.sh" 2> /dev/null | sed -n 's/=true$//p' | sort | tr '\n' ' ')
    want=$(printf '%s\n' $want | sed '/^$/d' | sort | tr '\n' ' ')
    if [ "$got" != "$want" ]; then
        echo "classify_changes_test: classify_pr.sh: want [$want], got [$got] for $files heads $heads $*" >&2
        fail=1
    fi
}
rename='[{"filename":"notes/x.md","previous_filename":"docs/ERRORS.md"}]'
pr_says "unit macos ci_scripts checks any" "$rename" 'aaa aaa'
pr_says "" '[{"filename":"README.md"}]' 'aaa aaa'
pr_says "" '[{"filename":"README.md","previous_filename":null}]' 'aaa aaa'
pr_says "$everything" "$rename" 'aaa bbb'
pr_says "$everything" "$rename" 'bbb aaa'
pr_says "$everything" "$rename" 'aaa aaa' HEAD_SHA=bbb
pr_says "$everything" "$rename" 'aaa aaa' HEAD_SHA=
pr_says "$everything" "$rename" 'aaa'
pr_says "$everything" "$rename" 'aaa aaa' STUB_FILES_FAIL=1
pr_says "$everything" "$rename" 'aaa aaa' EVENT=push
pr_says "$everything" "$rename" 'aaa aaa' PR=
pr_says "$everything" "$rename" 'aaa aaa' CHANGED=3
pr_says "$everything" '[]' 'aaa aaa'
# The count is of files, not names: a rename lists two names and counts once. The second review's
# case: a rename and README.md against changed_files=3 is a list one file short, so it fails closed.
two_files='[{"filename":"tests/views/new.py","previous_filename":"tests/views/old.py"},{"filename":"README.md"}]'
pr_says "views checks any" "$two_files" 'aaa aaa' CHANGED=2
pr_says "$everything" "$two_files" 'aaa aaa' CHANGED=3
pr_says "$everything" "$two_files" 'aaa aaa' CHANGED=
# NRV-E1252: classify_pr.sh says why every class runs; NRV-E1251: the classifier's usage error.
err=$(env PATH="$stub:$PATH" STUB_DIR="$stub" EVENT=pull_request PR= HEAD_SHA=aaa CHANGED=1 REPO=o/r "$here/classify_pr.sh" 2>&1 > /dev/null || true)
case $err in *'error[NRV-E1252]: classify_pr.sh: '*) ;; *) echo "classify_changes_test: classify_pr.sh fails closed without NRV-E1252: $err" >&2; fail=1 ;; esac
status=0
err=$("$here/classify_changes.sh" --bogus 2>&1 < /dev/null) || status=$?
case $err in *'error[NRV-E1251]: classify_changes.sh: usage'*) ;; *) echo "classify_changes_test: the usage error lacks NRV-E1251: $err" >&2; fail=1 ;; esac
if [ "$status" != 2 ]; then echo "classify_changes_test: the usage error exits $status, want 2" >&2; fail=1; fi

# ci.yml's `classify` step, run as GitHub runs it (bash -e) with the stand-in `gh`: a pull request that
# changes the workflows, the classifier or the actions has every class true, whatever the classifier
# says; and the second review's selfgate mutant (a classifier arm that swallows its own change) cannot
# skip the run.
step_script="$tmp/step.sh"
python3 -I - "$root/.github/workflows/ci.yml" > "$step_script" <<'PY'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["changes"]["steps"]
print([s for s in steps if s.get("id") == "classify"][0]["run"])
PY
# step_says <scripts dir> "<true classes>" '<files json>' [env VAR=value ...]
step_says() {
    local scripts=$1 want=$2 files=$3 out got status=0
    shift 3
    out="$tmp/step.out"
    : > "$out"
    rm -f "$stub/n"
    printf '%s' "$files" > "$stub/files.json"
    printf 'aaa\naaa\n' > "$stub/heads"
    (cd "$scripts/../.." && env PATH="$stub:$PATH" STUB_DIR="$stub" EVENT=pull_request PR=7 HEAD_SHA=aaa CHANGED=1 \
        REPO=o/r GITHUB_OUTPUT="$out" "$@" bash -e "$step_script" > /dev/null 2>&1) || status=$?
    got=$(sed -n 's/=true$//p' "$out" | sort | tr '\n' ' ')
    want=$(printf '%s\n' $want | sed '/^$/d' | sort | tr '\n' ' ')
    # A step that fails runs every job's steps too (`!= 'false'` on an empty output), so failing is closed.
    if [ "$status" != 0 ] && [ -z "$got" ]; then return; fi
    if [ "$got" != "$want" ] || [ "$status" != 0 ]; then
        echo "classify_changes_test: ci.yml classify step: want [$want], got [$got] (exit $status) for $files $*" >&2
        fail=1
    fi
}
step_says "$here" "" '[{"filename":"README.md"}]'
step_says "$here" "$everything" '[{"filename":".github/workflows/ci.yml"}]'
step_says "$here" "$everything" '[{"filename":".github/scripts/classify_changes.sh"}]'
step_says "$here" "$everything" '[{"filename":".github/scripts/classify_guard.py"}]'
step_says "$here" "$everything" '[{"filename":".github/actions/x/action.yml"}]'
step_says "$here" "$everything" '[{"filename":"notes/old.md","previous_filename":".github/workflows/ci.yml"}]'
step_says "$here" "$everything" '[{"filename":"README.md"},{"filename":".github/workflows/ci.yml"}]' CHANGED=2
step_says "$here" "$everything" '[{"filename":"README.md"}]' EVENT=push
step_says "$here" "$everything" '[{"filename":"README.md"}]' STUB_FILES_FAIL=1
selfgate="$tmp/selfgate"
mkdir -p "$selfgate/.github/scripts"
cp "$here/classify_changes.sh" "$here/classify_pr.sh" "$selfgate/.github/scripts/"
sed -i 's|^        # CI plumbing every job uses, and this classifier and its tests: everything runs.$|        .github/ISSUE_TEMPLATE/* \| .github/*) ;;\n&|' "$selfgate/.github/scripts/classify_changes.sh"
if ! grep -q 'ISSUE_TEMPLATE' "$selfgate/.github/scripts/classify_changes.sh"; then
    echo "classify_changes_test: the selfgate mutant did not apply" >&2
    fail=1
fi
# The mutant classifier alone leaves the classifier's own change with no class: that was the hole.
mutant=$(printf '.github/scripts/classify_changes.sh\n.github/scripts/classify_changes_test.sh\n' \
    | "$selfgate/.github/scripts/classify_changes.sh" --expect 2 | sed -n 's/=true$//p' | tr '\n' ' ')
if [ -n "$mutant" ]; then echo "classify_changes_test: the selfgate mutant selects [$mutant]" >&2; fail=1; fi
# The step forces every class on top of it.
step_says "$selfgate/.github/scripts" "$everything" '[{"filename":".github/scripts/classify_changes.sh"},{"filename":".github/scripts/classify_changes_test.sh"}]' CHANGED=2

[ "$fail" = 0 ] && echo "classify_changes_test: ok"
exit "$fail"
