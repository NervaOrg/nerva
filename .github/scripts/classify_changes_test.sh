#!/usr/bin/env bash
# Table test for classify_changes.sh against the manifest .github/test-inputs.txt, the guard's own
# tests (classify_guard.py: the manifest lint and the workflows' wiring), and the steps that run the
# classifier, run as GitHub runs them with a stand-in `gh`. Decision O14.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
fail=0

suites="unit fuzz vopr targets integration api views release demo demo_r4 demo_r5 macos packaging ci_scripts"
everything="all any $suites mac_keychain checks"

# check "<true classes, space separated>" "<changed files, newline separated>" [classifier args]
check() {
    local want got files=$2
    want=$(printf '%s\n' $1 | sed '/^$/d' | sort | tr '\n' ' ')
    shift 2
    got=$(printf '%s' "$files" | "$here/classify_changes.sh" "$@" | sed -n 's/=true$//p' | sort | tr '\n' ' ')
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

# Fail closed: an empty list, a list of nothing, and a file nothing places (coarse by default).
check "$everything" ''
check "$everything" $'\n\n'
check "$everything" 'LICENSE'
check "$everything" '.gitignore'
check "$everything" 'notes.md.zig'
check "$everything" 'docs/a.markdown'
check "$everything" 'docs/img.png'
check "$everything" 'newdir/x.py'
check "$everything" 'tests/newsuite/x.py'
check "$everything" 'tests/demo/other.py'
check "$everything" 'docs/INSTALL.md.bak.md'
check "$everything" $'README.md\nnewdir/x.py'
check "$everything" '.github/CODEOWNERS'
# A list the API cut short: fewer files than the pull request changed, or 3000 or more.
check "$everything" 'README.md' --expect 2
check "$everything" 'README.md' --expect ''
check "$everything" 'README.md' --expect many
check "$everything" 'README.md' --expect 0
check "$everything" 'README.md' --expect
check "" 'README.md' --expect 1
check "$everything" "$(seq 1 3000 | sed 's|^|docs/decisions/n|; s|$|.md|')" --expect 3000
check "" "$(seq 1 2999 | sed 's|^|docs/decisions/n|; s|$|.md|')" --expect 2999
check "$everything" 'README.md' --all
check "" $'README.md\nworklog/1.md' --expect 2

# Documentation that nothing reads: nothing runs (N68).
check "" 'README.md'
check "" $'README.md\ndocs/decisions/O14-x.md\nworklog/14.md\n'
check "" 'docs/briefs/r5.md'
check "" 'SECURITY.md'
check "" 'CLAUDE.md'
check "" 'docs/releases/v0.7.1-audit.md'
check "" 'docs/test-plan-r1.md'
# Markdown that a test reads: the classes that read it, or everything.
check "$everything" 'docs/ERRORS.md'
check "$everything" 'UPSTREAM.md'
check "ci_scripts checks any" 'CHANGELOG.md'
check "ci_scripts packaging checks any" 'docs/QUICKSTART.md'
check "ci_scripts checks any" 'docs/releases/automation.md'
check "packaging ci_scripts checks any" 'docs/releases/packages.md'
check "api any" 'docs/API.md'
check "packaging checks any" 'docs/INSTALL.md'
check "$everything" 'ops/jepsen/README.md'
check "$everything" $'README.md\nUPSTREAM.md'

# The binary's inputs, the toolchain, CI plumbing and the classifier itself: everything.
for f in src/nerva.zig src/vsr/replica.zig build.zig build.zig.zon zig/download.sh VERSION .gitmodules \
    .gitattributes src/.gitattributes docs/.gitattributes ci/job.sh ci/lib.sh ci/install_zig.sh ci/changes.sh \
    ci/ci_test.sh ci/woodpecker_step.sh ci/cache.sh .github/workflows/ci.yml .github/workflows/packages.yml \
    .github/workflows/release.yml .github/actions/zig-build-cache/action.yml \
    .github/scripts/classify_changes.sh .github/scripts/classify_changes_test.sh .github/scripts/classify_guard.py \
    .github/scripts/classify_pr.sh .github/test-inputs.txt .woodpecker/api.yaml ops/ci/README.md \
    scripts/quickstart_loop.sh perf/nightly/compare.py release/candidate tests/jepsen/run.sh \
    .github/scripts/sbom.py .github/scripts/docs_only.sh .github/scripts/release_check.sh; do
    check "$everything" "$f"
done
check "$everything" $'README.md\nsrc/nerva.zig'

# One suite's own files select that suite (and what shares them).
check "api integration any" 'tests/api/api.py'
check "api any" 'tests/api/docs_routes.py'
check "api integration any" 'tests/errors/wire.py'
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
check "packaging ci_scripts checks any" '.github/scripts/package_repos.sh'
check "packaging ci_scripts checks any" '.github/scripts/r2.py'
check "packaging ci_scripts checks any" '.github/scripts/pre_p417_tags'
check "packaging ci_scripts checks any" '.github/scripts/test_package_repos.py'
check "mac_keychain ci_scripts checks any" '.github/scripts/mac_keychain.sh'
check "mac_keychain ci_scripts checks any" '.github/scripts/test_mac_sign.py'
# Unions.
check "api release any" $'tests/api/a.py\ntests/release/b.py'
check "views checks any" $'README.md\ntests/views/x.py'
check "demo demo_r4 any" $'demo/common.py\ntests/demo/r4.py'
check "api any" $'README.md\ndocs/API.md'

# A rename lists both names (the API's `filename` and `previous_filename`): the old path is a
# deletion, and both are classified. The new name alone selects nothing, which is the bug a list
# without previous_filename had.
check "" $'docs/decisions/x.md\tdocs/decisions/y.md' --expect 1
check "api any" $'docs/decisions/n.md\tdocs/API.md' --expect 1
check "packaging checks any" $'docs/decisions/n.md\tdocs/INSTALL.md' --expect 1
check "api integration any" $'docs/decisions/n.md\ttests/api/api.py' --expect 1
check "views checks any" $'docs/decisions/n.md\ttests/views/declared.py' --expect 1
check "release any" $'docs/decisions/n.md\ttests/release/mixed.py' --expect 1
check "demo any" $'docs/decisions/n.md\tdemo/common.py' --expect 1
check "$everything" $'docs/decisions/n.md\tdocs/ERRORS.md' --expect 1
check "$everything" $'docs/decisions/n.md\tsrc/nerva/wire_code.zig' --expect 1
check "$everything" $'docs/decisions/n.md\t.github/workflows/ci.yml' --expect 1
check "$everything" $'docs/decisions/n.md\t.github/scripts/classify_changes.sh' --expect 1
check "$everything" $'docs/decisions/n.md\t.github/test-inputs.txt' --expect 1
# A rename INTO the floor is the floor too.
check "$everything" $'.github/workflows/new.yml\tdocs/decisions/y.md' --expect 1
# --expect counts files, one line each (a rename is one file of two names), not names: a list with
# a rename that is missing a file is truncated, though it has as many names as the files changed.
check "$everything" $'tests/views/new.py\ttests/views/old.py\nREADME.md' --expect 3
check "$everything" $'tests/views/new.py\ttests/views/old.py\nREADME.md\nsrc/x.zig' --expect 3
check "views checks any" $'tests/views/new.py\ttests/views/old.py\nREADME.md\nworklog/x.md' --expect 3
check "$everything" $'a.md\tb.md\tc.md' --expect 2
check "" $'docs/decisions/a.md\tdocs/decisions/b.md\nworklog/c.md' --expect 2
check "api any" $'docs/decisions/a.md\tdocs/API.md\ndocs/decisions/b.md\nREADME.md' --expect 3
check "$everything" $'docs/decisions/a.md\nREADME.md' --expect 3

# The manifest: a rule the classifier cannot read is a usage error (exit 2, NRV-E1251), never a
# narrowing. The floor holds whatever the manifest says.
manifest_says() { # manifest_says <fragment> <manifest text>
    local out status=0
    printf '%s\n' "$2" > "$tmp/m.txt"
    out=$(printf 'README.md\n' | CLASSIFY_MANIFEST="$tmp/m.txt" "$here/classify_changes.sh" 2>&1) || status=$?
    if [ "$status" != 2 ]; then
        echo "classify_changes_test: a manifest [$2] exits $status, want 2: $out" >&2
        fail=1
    elif ! printf '%s' "$out" | grep -qF "error[NRV-E1251]: classify_changes.sh: " || ! printf '%s' "$out" | grep -qF -- "$1"; then
        echo "classify_changes_test: a manifest [$2] does not say NRV-E1251 and '$1': $out" >&2
        fail=1
    fi
}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
manifest_says "unknown class 'apii'" 'apii tests/api/*'
manifest_says "unknown class 'unit'" 'unit tests/api/*'
manifest_says "a rule is '<class> <glob>'" 'api'
manifest_says "a rule is '<class> <glob>'" 'api tests/api/* extra'
manifest_says "has no rule" '# nothing'
if printf 'README.md\n' | CLASSIFY_MANIFEST="$tmp/none.txt" "$here/classify_changes.sh" > /dev/null 2>&1; then
    echo "classify_changes_test: a missing manifest was accepted" >&2
    fail=1
fi
printf 'none .github/workflows/*\nnone .github/actions/*\nnone .github/scripts/classify_*\nnone .github/test-inputs.txt\napi tests/api/*\n' > "$tmp/weak.txt"
export CLASSIFY_MANIFEST="$tmp/weak.txt"
check "$everything" '.github/workflows/ci.yml'
check "$everything" '.github/actions/x/action.yml'
check "$everything" '.github/scripts/classify_changes.sh'
check "$everything" '.github/test-inputs.txt'
check "api any" 'tests/api/x.py'
# The union of every rule that matches; `none` adds nothing; an unmatched path is everything.
printf 'none docs/*\napi docs/API.md\nviews docs/API.md\n' > "$tmp/union.txt"
export CLASSIFY_MANIFEST="$tmp/union.txt"
check "api views checks any" 'docs/API.md'
check "" 'docs/other.md'
check "$everything" 'other/x'
unset CLASSIFY_MANIFEST

# The guard passes on this repository.
if ! python3 -I "$here/classify_guard.py" --root "$root" > /dev/null 2> "$tmp/guard.err"; then
    echo "classify_changes_test: the guard fails on this repository:" >&2
    cat "$tmp/guard.err" >&2
    fail=1
fi

# The lint, on small trees with a manifest of their own: a literal path or an import in a suite's
# file that the manifest does not select for that suite fails. Best effort: see the cases that pass.
ltree() { # ltree <name>: a repository with an api suite (tests/api), a demo suite and a manifest
    local t="$tmp/$1"
    mkdir -p "$t/.github" "$t/tests/api" "$t/tests/shared" "$t/demo" "$t/src" "$t/docs"
    cat > "$t/.github/test-inputs.txt" <<'TXT'
all src/*
all docs/ERRORS.md
all UPSTREAM.md
none README.md
api docs/API.md
api tests/api/*
demo demo/*
TXT
    echo x > "$t/demo/x.py"; echo x > "$t/src/x.zig"; echo x > "$t/docs/API.md"; echo x > "$t/docs/ERRORS.md"
    echo x > "$t/UPSTREAM.md"; echo x > "$t/README.md"; echo x > "$t/tests/shared/data.txt"
    printf 'def f():\n    pass\n' > "$t/demo/helper.py"
    printf 'def f():\n    pass\n' > "$t/tests/api/own.py"
    printf '%s\n' "${2:-x = 1}" > "$t/tests/api/a.py"
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
lint() { # lint <want exit> <name> <body of tests/api/a.py> [fragment]
    ltree "$2" "$3"
    guard_in "$1" "$2" "${4:-}"
}
lint 0 lint_ok 'import os
import own
x = "docs/API.md"'
lint 0 lint_all 'x = "docs/ERRORS.md"
y = "UPSTREAM.md"
z = "src/x.zig"'
lint 1 lint_literal 'x = "demo/x.py"' 'names demo/x.py'
lint 1 lint_readme 'x = "README.md"' 'does not select api'
lint 1 lint_relative 'open("../../demo/x.py")' 'names demo/x.py'
lint 1 lint_import 'import helper' 'import helper'
lint 1 lint_from_import 'from helper import f' 'names demo/helper.py'
# pkg_import (the third review): a package or a dotted import names the package's files.
ltree lint_pkg_import 'from pkg.sub import x'
mkdir -p "$tmp/lint_pkg_import/demo/pkg"
echo x > "$tmp/lint_pkg_import/demo/pkg/__init__.py"
guard_in 1 lint_pkg_import 'import pkg'
ltree lint_pkg_dotted 'import pkg.sub'
mkdir -p "$tmp/lint_pkg_dotted/demo/pkg"
echo x > "$tmp/lint_pkg_dotted/demo/pkg/__init__.py"
guard_in 1 lint_pkg_dotted 'import pkg'
# A comment, a docstring and a mention in a message are not reads.
lint 0 lint_comment '# demo/x.py is not read
x = 1'
lint 0 lint_docstring '"""Reads demo/x.py, they say."""
x = 1'
# Shell files of a suite are scanned like any other (sh_upstream, sh_root_md of the third review).
ltree lint_sh_ok
printf 'cat UPSTREAM.md\ncat "$here/../docs/ERRORS.md"\ncat docs/API.md\n' > "$tmp/lint_sh_ok/tests/api/run.sh"
guard_in 0 lint_sh_ok
ltree lint_sh_root_md
printf 'root=$(cd "$(dirname "$0")/../.." && pwd)\ncat "$root/README.md"\n' > "$tmp/lint_sh_root_md/tests/api/run.sh"
guard_in 1 lint_sh_root_md 'names README.md'
ltree lint_sh_dir
printf 'cat "$root/demo/x.py"\n' > "$tmp/lint_sh_dir/tests/api/run.sh"
guard_in 1 lint_sh_dir 'names demo/x.py'
ltree lint_sh_comment
printf '# cat demo/x.py\necho hi\n' > "$tmp/lint_sh_comment/tests/api/run.sh"
guard_in 0 lint_sh_comment
# mac_not_root: the keychain job's scripts are a suite's own files, scanned for what they name.
ltree lint_mac
mkdir -p "$tmp/lint_mac/.github/scripts"
printf 'mac_keychain .github/scripts/mac_*\nci_scripts .github/scripts/mac_*\n' >> "$tmp/lint_mac/.github/test-inputs.txt"
printf 'cat docs/API.md\n' > "$tmp/lint_mac/.github/scripts/mac_x.sh"
guard_in 1 lint_mac 'does not select ci_scripts and mac_keychain'
printf 'cat docs/ERRORS.md\n' > "$tmp/lint_mac/.github/scripts/mac_x.sh"
guard_in 0 lint_mac
# A rule that matches no file is stale.
ltree lint_stale
printf 'api tests/gone/*\n' >> "$tmp/lint_stale/.github/test-inputs.txt"
guard_in 1 lint_stale 'matches no file'
# A manifest that is missing, or that the classifier refuses.
ltree lint_no_manifest
rm "$tmp/lint_no_manifest/.github/test-inputs.txt"
guard_in 1 lint_no_manifest 'does not exist'
ltree lint_bad_manifest
printf 'apii tests/api/*\n' >> "$tmp/lint_bad_manifest/.github/test-inputs.txt"
guard_in 1 lint_bad_manifest "unknown class 'apii'"
# The limits (O14, "Limits"): what the lint cannot see passes. These cases say so, so a change that
# starts to see them is noticed here, and a reader is not told the lint is a proof.
lint 0 limit_listdir 'import os
os.listdir("demo")'
lint 0 limit_glob 'import glob
glob.glob("demo/*.py")'
lint 0 limit_directory 'x = "demo/"'
lint 0 limit_computed 'import os
open(os.path.join("de" + "mo", "x" + ".py"))'
lint 0 limit_importlib 'import importlib
importlib.import_module("hel" + "per")'
# A tracked symbolic link, in a tree that is a git work tree.
ltree lint_symlink
ln -s ../../docs/API.md "$tmp/lint_symlink/tests/api/link.md"
git -C "$tmp/lint_symlink" init -q
git -C "$tmp/lint_symlink" add -f -A
guard_in 1 lint_symlink 'is a symbolic link'

# ci.yml: each way the guard says a gate is wrong. A job that waits for `changes`, with its steps.
system_needs="checks ci-scripts integration api releases targets macos-arm64 macos-x86_64 mac-keychain"
workflow_tree() { # workflow_tree <name> <sed over ci.yml> <job yaml>
    ltree "$1"
    mkdir -p "$tmp/$1/.github/workflows"
    {
        printf 'on: push\njobs:\n  changes:\n    runs-on: x\n    outputs:\n'
        for c in $everything; do printf '      %s: ${{ steps.classify.outputs.%s }}\n' "$c" "$c"; done
        printf '    steps:\n      - id: classify\n        run: x\n'
        printf '  system:\n    needs:\n'
        for j in $system_needs; do printf '      - %s\n' "$j"; done
        printf '    runs-on: x\n    steps: []\n%s\n' "$3"
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
workflow_tree wf_extra_output 's/^      all: .*/&\n      binary: ${{ steps.classify.outputs.binary }}/' "$(job unit changes "$ok")"
guard_in 1 wf_extra_output 'outputs binary, which is not a class'
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
# `continue-on-error` turns a failed suite into a pass: refused on a gated job and on a gated step.
workflow_tree wf_coe_job '/^  unit:/,$ s/^    runs-on: x$/    runs-on: x\n    continue-on-error: true/' "$(job unit changes "$ok")"
guard_in 1 wf_coe_job 'job unit has `continue-on-error`'
workflow_tree wf_coe_step '/^  unit:/,$ s/^      - run: a$/      - run: a\n        continue-on-error: true/' "$(job unit changes "$ok")"
guard_in 1 wf_coe_step 'has `continue-on-error`: a failed step'
# `system` is the required check: a job it stops waiting for can fail unseen.
workflow_tree wf_system_drop '/^      - targets$/d' "$(job unit changes "$ok")"
guard_in 1 wf_system_drop 'the required check `system` waits for'
workflow_tree wf_system_extra 's/^      - targets$/&\n      - extra/' "$(job unit changes "$ok")"
guard_in 1 wf_system_extra 'the required check `system` waits for'
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
guard_in 1 wf_cs_test_gated 'it runs on every pull request'
workflow_tree wf_cs_checkout_gated '' "$(ci_scripts_job "        if: needs.changes.outputs.any != 'false'" '        name: t')"
guard_in 1 wf_cs_checkout_gated 'it runs on every pull request'
workflow_tree wf_cs_no_test '' "$(ci_scripts_job '        name: c' '        name: t' | sed 's|classify_changes_test.sh|other.sh|')"
guard_in 1 wf_cs_no_test 'has no step that runs classify_changes_test.sh'
# Every push to main runs everything: a `paths-ignore` on `push` skips what a pull request skipped.
workflow_tree wf_push_ignore 's/^on: push/on:\n  push:\n    paths-ignore: ["**.md"]/' "$(job unit changes "$ok")"
guard_in 1 wf_push_ignore '`on.push` has `paths` or `paths-ignore`'
workflow_tree wf_push_paths 's/^on: push/on:\n  push:\n    paths: ["src\/**"]/' "$(job unit changes "$ok")"
guard_in 1 wf_push_paths '`on.push` has `paths` or `paths-ignore`'
workflow_tree wf_push_branches 's/^on: push/on:\n  push:\n    branches: [main]/' "$(job unit changes "$ok")"
guard_in 0 wf_push_branches

# packages.yml: the jobs wait for `classify` and run when it fails or says nothing.
packages_tree() { # packages_tree <name> <sed over packages.yml>
    workflow_tree "$1" '' "$(job unit changes "$ok")"
    cat > "$tmp/$1/.github/workflows/packages.yml" <<'YML'
on: push
jobs:
  classify:
    runs-on: x
    steps:
      - id: classify
        run: x
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
packages_tree pk_coe 's/^    runs-on: x$/&\n    continue-on-error: true/'
guard_in 1 pk_coe 'has `continue-on-error`'

# A workflow that calls another grants it what its jobs ask for (the next release failed at startup
# when release.yml called packages.yml without pull-requests: read).
call_tree() { # call_tree <name> <caller permissions yaml, indented 4> <callee job permissions yaml, indented 4>
    ltree "$1"
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
    echo read >> "$STUB_DIR/files_calls"
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
    rm -f "$stub/n"; : > "$stub/files_calls"
    printf '%s' "$files" > "$stub/files.json"
    printf '%s\n' $heads > "$stub/heads"
    got=$(env PATH="$stub:$PATH" STUB_DIR="$stub" EVENT=pull_request PR=7 HEAD_SHA=aaa CHANGED=1 REPO=o/r "$@" \
        "$here/classify_pr.sh" 2> /dev/null | sed -n 's/=true$//p' | sort | tr '\n' ' ')
    want=$(printf '%s\n' $want | sed '/^$/d' | sort | tr '\n' ' ')
    # The list is read once: a second read is a second chance to classify another head's files.
    if [ "$(wc -l < "$stub/files_calls")" -gt 1 ]; then
        echo "classify_changes_test: classify_pr.sh read the file list more than once for $files $*" >&2
        fail=1
    fi
    if [ "$got" != "$want" ]; then
        echo "classify_changes_test: classify_pr.sh: want [$want], got [$got] for $files heads $heads $*" >&2
        fail=1
    fi
}
rename='[{"filename":"docs/decisions/x.md","previous_filename":"docs/ERRORS.md"}]'
pr_says "$everything" "$rename" 'aaa aaa'
pr_says "api any" '[{"filename":"docs/decisions/x.md","previous_filename":"docs/API.md"}]' 'aaa aaa'
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
# changed_files 0 or missing fails closed: a pull request has at least one file.
pr_says "$everything" '[{"filename":"README.md"}]' 'aaa aaa' CHANGED=0
pr_says "$everything" '[{"filename":"README.md"}]' 'aaa aaa' CHANGED=
pr_says "$everything" '[{"filename":"README.md"}]' 'aaa aaa' CHANGED=many
# The count is of files, not names: a rename lists two names and counts once. The second review's
# case: a rename and README.md against changed_files=3 is a list one file short, so it fails closed.
two_files='[{"filename":"tests/views/new.py","previous_filename":"tests/views/old.py"},{"filename":"README.md"}]'
pr_says "views checks any" "$two_files" 'aaa aaa' CHANGED=2
pr_says "$everything" "$two_files" 'aaa aaa' CHANGED=3
pr_says "$everything" "$two_files" 'aaa aaa' CHANGED=
# The floor reaches classify_pr.sh's output: the workflows, the classifier and the manifest.
pr_says "$everything" '[{"filename":".github/workflows/ci.yml"}]' 'aaa aaa'
pr_says "$everything" '[{"filename":"README.md"},{"filename":".github/test-inputs.txt"}]' 'aaa aaa' CHANGED=2
# NRV-E1252: classify_pr.sh says why every class runs; NRV-E1251: the classifier's usage error.
err=$(env PATH="$stub:$PATH" STUB_DIR="$stub" EVENT=pull_request PR= HEAD_SHA=aaa CHANGED=1 REPO=o/r "$here/classify_pr.sh" 2>&1 > /dev/null || true)
case $err in *'error[NRV-E1252]: classify_pr.sh: '*) ;; *) echo "classify_changes_test: classify_pr.sh fails closed without NRV-E1252: $err" >&2; fail=1 ;; esac
err=$(env PATH="$stub:$PATH" STUB_DIR="$stub" EVENT=pull_request PR=7 HEAD_SHA=aaa CHANGED=0 REPO=o/r "$here/classify_pr.sh" 2>&1 > /dev/null || true)
case $err in *'error[NRV-E1252]: classify_pr.sh: the event'*'changed_files'*) ;; *) echo "classify_changes_test: changed_files 0 fails without NRV-E1252: $err" >&2; fail=1 ;; esac
status=0
err=$("$here/classify_changes.sh" --bogus 2>&1 < /dev/null) || status=$?
case $err in *'error[NRV-E1251]: classify_changes.sh: usage'*) ;; *) echo "classify_changes_test: the usage error lacks NRV-E1251: $err" >&2; fail=1 ;; esac
if [ "$status" != 2 ]; then echo "classify_changes_test: the usage error exits $status, want 2" >&2; fail=1; fi
# If even `--all` fails, classify_pr.sh fails (the step fails, its output is empty, everything runs):
# it never exits 0 with nothing printed.
brokendir="$tmp/broken/.github/scripts"
mkdir -p "$brokendir"
cp "$here/classify_pr.sh" "$brokendir/"
printf '#!/usr/bin/env bash\nexit 1\n' > "$brokendir/classify_changes.sh"
chmod +x "$brokendir/classify_changes.sh"
status=0
out=$(env EVENT=push "$brokendir/classify_pr.sh" 2> /dev/null) || status=$?
if [ "$status" = 0 ] || [ -n "$out" ]; then
    echo "classify_changes_test: classify_pr.sh exits $status with [$out] when --all fails" >&2
    fail=1
fi

# The steps that run the classifier, as GitHub runs them (bash -e) with the stand-in `gh`, from a
# repository root of their own: ci.yml's `classify` step and packages.yml's.
step_of() { # step_of <workflow> <job> > script: the `run` of the job's step with id `classify`
    python3 -I - "$root/.github/workflows/$1" "$2" <<'PY'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"][sys.argv[2]]["steps"]
print([s for s in steps if s.get("id") == "classify"][0]["run"])
PY
}
step_of ci.yml changes > "$tmp/ci_step.sh"
step_of packages.yml classify > "$tmp/pk_step.sh"
run_step() { # run_step <script> <repo root> <files json> [env VAR=value ...]: sets $status, writes $tmp/step.out
    local script=$1 repo=$2 files=$3
    shift 3
    : > "$tmp/step.out"
    rm -f "$stub/n"
    printf '%s' "$files" > "$stub/files.json"
    printf 'aaa\naaa\n' > "$stub/heads"
    status=0
    (cd "$repo" && env PATH="$stub:$PATH" STUB_DIR="$stub" EVENT=pull_request PR=7 HEAD_SHA=aaa CHANGED=1 \
        REPO=o/r GITHUB_OUTPUT="$tmp/step.out" "$@" bash -e "$script" > /dev/null 2>&1) || status=$?
}
# step_says "<true classes>" '<files json>' [env ...]: a step that fails has an empty output, and
# an empty output runs every job (`!= 'false'`), so failing is closed.
step_says() {
    local want=$1 files=$2 got
    shift 2
    run_step "$tmp/ci_step.sh" "${STEP_ROOT:-$root}" "$files" "$@"
    got=$(sed -n 's/=true$//p' "$tmp/step.out" | sort | tr '\n' ' ')
    want=$(printf '%s\n' $want | sed '/^$/d' | sort | tr '\n' ' ')
    if [ "$status" != 0 ] && [ -z "$got" ]; then return; fi
    if [ "$got" != "$want" ] || [ "$status" != 0 ]; then
        echo "classify_changes_test: ci.yml classify step: want [$want], got [$got] (exit $status) for $files $*" >&2
        fail=1
    fi
}
step_says "" '[{"filename":"README.md"}]'
step_says "api any" '[{"filename":"docs/API.md"}]'
step_says "$everything" '[{"filename":".github/workflows/ci.yml"}]'
step_says "$everything" '[{"filename":".github/scripts/classify_changes.sh"}]'
step_says "$everything" '[{"filename":".github/scripts/classify_guard.py"}]'
step_says "$everything" '[{"filename":".github/test-inputs.txt"}]'
step_says "$everything" '[{"filename":".github/actions/x/action.yml"}]'
step_says "$everything" '[{"filename":"docs/decisions/old.md","previous_filename":".github/workflows/ci.yml"}]'
step_says "$everything" '[{"filename":"README.md"},{"filename":".github/workflows/ci.yml"}]' CHANGED=2
step_says "$everything" '[{"filename":"README.md"}]' EVENT=push
step_says "$everything" '[{"filename":"README.md"}]' STUB_FILES_FAIL=1
step_says "$everything" '[{"filename":"README.md"}]' CHANGED=0
# pk_says <want: true|false|closed> '<files json>' [env ...]: `run` is false only for an explicit
# all=false and packaging=false. A step that fails, or garbled or empty output, runs the jobs.
pk_says() {
    local want=$1 files=$2 got
    shift 2
    run_step "$tmp/pk_step.sh" "${STEP_ROOT:-$root}" "$files" "$@"
    got=$(sed -n 's/^run=//p' "$tmp/step.out" | tail -1)
    case $want in
    closed) [ "$got" != false ] || { echo "classify_changes_test: packages.yml classify step skips the jobs: $files $*" >&2; fail=1; } ;;
    *) if [ "$got" != "$want" ] || [ "$status" != 0 ]; then
        echo "classify_changes_test: packages.yml classify step: want run=$want, got [$got] (exit $status) for $files $*" >&2
        fail=1
    fi ;;
    esac
}
pk_says false '[{"filename":"README.md"}]'
pk_says false '[{"filename":"tests/api/api.py"}]'
pk_says true '[{"filename":"docs/INSTALL.md"}]'
pk_says true '[{"filename":"tests/packaging/install.py"}]'
pk_says true '[{"filename":"src/nerva.zig"}]'
pk_says true '[{"filename":".github/workflows/packages.yml"}]'
pk_says true '[{"filename":".github/scripts/classify_changes.sh"}]'
pk_says true '[{"filename":".github/test-inputs.txt"}]'
pk_says true '[{"filename":"docs/decisions/x.md","previous_filename":".github/workflows/packages.yml"}]'
pk_says true '[{"filename":"README.md"}]' EVENT=push
pk_says true '[{"filename":"README.md"}]' STUB_FILES_FAIL=1
pk_says true '[{"filename":"README.md"}]' CHANGED=0
# Garbled, empty and failing classifier output (the third review): the jobs run.
fake="$tmp/fake"
mkdir -p "$fake/.github/scripts"
fake_says() { # fake_says <want> <body of classify_pr.sh>
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "$fake/.github/scripts/classify_pr.sh"
    chmod +x "$fake/.github/scripts/classify_pr.sh"
    STEP_ROOT=$fake pk_says "$1" '[]'
}
fake_says true 'echo garbage'
fake_says true 'true'
fake_says true 'echo all=false'
fake_says true 'echo packaging=false'
fake_says true "printf 'all=false\\npackaging=true\\n'"
fake_says true "printf 'all=true\\npackaging=false\\n'"
fake_says true "printf 'all=false\\nxpackaging=false\\n'"
fake_says closed 'exit 1'
fake_says false "printf 'all=false\\npackaging=false\\n'"

[ "$fail" = 0 ] && echo "classify_changes_test: ok"
exit "$fail"
