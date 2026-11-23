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
check "unit macos ci_scripts checks any" $'notes/x.md\ndocs/ERRORS.md' --expect 1
check "unit macos ci_scripts checks any" $'docs/ERRORS-old.md\ndocs/ERRORS.md' --expect 1
check "api any" $'docs/HTTP.md\ndocs/API.md' --expect 1
check "$binary_set" $'notes/wire_code.md\nsrc/nerva/wire_code.zig' --expect 1
check "api integration any" $'docs/api.md\ntests/api/api.py' --expect 1
check "packaging checks any" $'docs/old.md\ndocs/INSTALL.md' --expect 1
check "packaging ci_scripts checks any" $'docs/old.md\ndocs/releases/packages.md' --expect 1
check "ci_scripts checks any" $'docs/old.md\nUPSTREAM.md' --expect 1
check "views checks any" $'notes/x.md\ntests/views/declared.py' --expect 1
check "release any" $'notes/x.md\ntests/release/mixed.py' --expect 1
check "demo any" $'notes/x.md\ndemo/common.py' --expect 1
check "packaging ci_scripts checks any" $'notes/x.md\n.github/scripts/pre_p417_tags' --expect 1
# A list longer than changed_files (renames) is whole; a shorter one is truncated.
check "unit macos ci_scripts checks any" $'a.md\ndocs/ERRORS.md\nb.md\nREADME.md' --expect 3
check "$everything" $'a.md\nREADME.md' --expect 3
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
workflow_tree() { # workflow_tree <name> <outputs override sed> <job yaml>
    tree "$1" 'x = 1'
    mkdir -p "$tmp/$1/.github/workflows"
    {
        printf 'on: push\njobs:\n  changes:\n    runs-on: x\n    outputs:\n'
        for c in $everything; do printf '      %s: ${{ steps.classify.outputs.%s }}\n' "$c" "$c"; done
        printf '    steps: []\n%s\n' "$3"
    } > "$tmp/$1/.github/workflows/ci.yml"
    if [ -n "$2" ]; then sed -i "$2" "$tmp/$1/.github/workflows/ci.yml"; fi
}
job() { # job <name> <needs> <condition>: a job of two steps gated on <condition>
    printf '  %s:
    needs: %s
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
guard_in 1 wf_fail_open 'every term must be'
workflow_tree wf_or_true '' "$(job unit changes "needs.changes.outputs.unit != 'false' || true")"
guard_in 1 wf_or_true 'every term must be'
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

[ "$fail" = 0 ] && echo "classify_changes_test: ok"
exit "$fail"
