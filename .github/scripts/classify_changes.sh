#!/usr/bin/env bash
# Reads a pull request's changed files on stdin, one file per line, and prints one `class=true|false`
# line per class: which parts of CI the change can affect (decision O14, which amends N68). A renamed
# file is one line of two names separated by a tab (`new<TAB>old`): the old path is a deletion, and
# both are classified. `--all` prints every class true (a push to main, a release, a dispatch, a
# list that could not be had: the callers fail closed). `--expect N` says how many files the pull
# request changed (`changed_files` of the event); a list of fewer lines (files, not names) than that,
# or as long as the 3000 files the API lists at most, is truncated, and every class is true. So is
# an N that is not a positive number.
#
# Coarse by default. The rules are the hand-kept manifest .github/test-inputs.txt (`<class> <glob>`;
# CLASSIFY_MANIFEST names another, for tests). A path that no rule matches, a path with an `all`
# rule and an empty list run every class. A skip claims only that this change cannot have caused a
# regression in a suite: none of the files the manifest says it reads changed. It certifies nothing
# else: flakes and drift are caught by pushes to main, which run everything (O14).
#
# The floor below is not in the manifest's reach: the workflows, the actions, the classifier and the
# manifest itself run everything, so a broken manifest cannot narrow the pull request that breaks it.
#
#   all           every class
#   any           anything at all changed that something reads: gates what is never skipped by diff
#                 (VOPR's random seed)
#   unit fuzz vopr targets
#                 only `all` selects them (the Zig sources, build.zig and the like)
#   integration api views release demo demo_r4 demo_r5 macos packaging ci_scripts mac_keychain
#                 the suite of that name; its jobs run when the class is true
#   checks        the `checks` job: views, ci_scripts or packaging (derived)
set -eu

here=$(cd "$(dirname "$0")" && pwd)
manifest=${CLASSIFY_MANIFEST:-$here/../test-inputs.txt}

suites="unit fuzz vopr targets integration api views release demo demo_r4 demo_r5 macos packaging ci_scripts"
all_classes="all any $suites mac_keychain checks"
# The classes a manifest rule may name, besides `all` and `none`.
rule_classes=" integration api views release demo demo_r4 demo_r5 macos packaging ci_scripts mac_keychain "

declare -A on=()
for c in $all_classes; do on[$c]=false; done

raise() { local c; for c in "$@"; do on[$c]=true; done; }
raise_all() { raise $all_classes; }

usage() {
    echo "error[NRV-E1251]: classify_changes.sh: $1" >&2
    exit 2
}

expect=
syntax="usage: classify_changes.sh [--all | --expect <changed files>] < files, one per line (a rename: new<TAB>old)"
case "${1:-}" in
--all) [ "$#" = 1 ] || usage "$syntax"; raise_all ;;
--expect)
    # `--expect` with no number is a cut list (everything runs); any argument beyond it is a usage error.
    [ "$#" -le 2 ] || usage "$syntax"
    expect="${2:-}"; [[ "$expect" =~ ^[1-9][0-9]*$ ]] || raise_all ;;
"") [ "$#" = 0 ] || usage "$syntax" ;;
*) usage "$syntax" ;;
esac

# The manifest: `<class> <glob>` per line, `#` comments, blank lines. A rule it cannot read is an
# error (the callers fail closed: the run is not skipped).
rule_class=()
rule_glob=()
if [ "${on[all]}" = false ]; then
    [ -r "$manifest" ] || usage "the manifest $manifest cannot be read"
    n=0
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        line=${line%%#*}
        read -r -a f <<< "$line" || true
        [ "${#f[@]}" -gt 0 ] || continue
        [ "${#f[@]}" = 2 ] || usage "$manifest:$n: a rule is '<class> <glob>'"
        case "${f[0]}" in
        all | none) ;;
        *) case "$rule_classes" in *" ${f[0]} "*) ;; *) usage "$manifest:$n: unknown class '${f[0]}'" ;; esac ;;
        esac
        rule_class+=("${f[0]}")
        rule_glob+=("${f[1]}")
    done < "$manifest"
    [ "${#rule_class[@]}" -gt 0 ] || usage "the manifest $manifest has no rule"
fi

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
        # The floor: the plumbing and the classifier run everything, whatever the manifest says.
        .github/workflows/* | .github/actions/* | .github/scripts/classify_* | .github/test-inputs.txt)
            raise_all ;;
        esac
        [ "${on[all]}" = false ] || break
        matched=false
        for i in "${!rule_glob[@]}"; do
            # shellcheck disable=SC2053  # an unquoted right side is a glob: that is the rule
            if [[ "$file" == ${rule_glob[$i]} ]]; then
                matched=true
                case "${rule_class[$i]}" in
                all) raise_all ;;
                none) ;;
                *) raise "${rule_class[$i]}" ;;
                esac
            fi
        done
        # Unplaced: everything runs.
        [ "$matched" = true ] || raise_all
    done
fi

# `all` is every class.
if [ "${on[all]}" = true ]; then raise_all; fi
if [ "${on[views]}" = true ] || [ "${on[ci_scripts]}" = true ] || [ "${on[packaging]}" = true ]; then
    raise checks
fi
for c in $suites mac_keychain checks; do
    if [ "${on[$c]}" = true ]; then raise any; fi
done

for c in $all_classes; do echo "$c=${on[$c]}"; done
