#!/usr/bin/env bash
# Prints the change classes of a pull request, one `class=true|false` line each (decision O14):
# fetches the pull request's changed files from the API and hands them to classify_changes.sh.
# Everything that cannot be known fails closed, every class true:
#   - the event is not a pull request (a push to main, a release's call, a dispatch);
#   - the head the list describes is not the head this run was started for: the pull request's head
#     is read before and after the list and must equal HEAD_SHA, the event's pull_request.head.sha
#     (a push or a force-push in between would otherwise classify one commit with another's files);
#   - the API fails, or the list has fewer files than the pull request's changed_files, or is truncated.
# One line per file, as classify_changes.sh reads it: a renamed file lists both its names
# (`filename` and `previous_filename`, a tab between), since the old path is a deletion. The lines
# are counted, not the names, against changed_files.
#
# Environment: EVENT PR HEAD_SHA CHANGED REPO, and GH_TOKEN for `gh`.
set -u
here=$(cd "$(dirname "$0")" && pwd)

fail_closed() {
    echo "error[NRV-E1252]: classify_pr.sh: $1: every class runs" >&2
    "$here/classify_changes.sh" --all < /dev/null
    exit 0
}

[ "${EVENT:-}" = pull_request ] && [ -n "${PR:-}" ] || fail_closed "not a pull request"
[ -n "${HEAD_SHA:-}" ] && [ -n "${REPO:-}" ] || fail_closed "no head SHA or repository in the event"

head_before=$(gh api "repos/$REPO/pulls/$PR" --jq .head.sha) || fail_closed "the pull request could not be read"
files=$(gh api "repos/$REPO/pulls/$PR/files" --paginate \
    --jq '.[] | [.filename, (.previous_filename // empty)] | @tsv') || fail_closed "the file list could not be read"
head_after=$(gh api "repos/$REPO/pulls/$PR" --jq .head.sha) || fail_closed "the pull request could not be read"

if [ "$head_before" != "$HEAD_SHA" ] || [ "$head_after" != "$HEAD_SHA" ]; then
    fail_closed "the pull request's head moved (event $HEAD_SHA, API $head_before then $head_after)"
fi

printf '%s\n' "$files" | "$here/classify_changes.sh" --expect "${CHANGED:-}"
