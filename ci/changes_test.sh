#!/usr/bin/env bash
# Table test for ci/changes.sh: a Markdown push skips only over a pipeline that succeeded.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
git init -q .
git config user.email ci@example.invalid
git config user.name ci
mkdir -p ci .github/scripts
cp "$root/ci/changes.sh" ci/
cp "$root/.github/scripts/docs_only.sh" .github/scripts/
echo a >code.zig && git add -A && git commit -qm code
base=$(git rev-parse HEAD)
echo b >notes.md && git add notes.md && git commit -qm docs
docs=$(git rev-parse HEAD)
echo c >>code.zig && git add code.zig && git commit -qm code2
code=$(git rev-parse HEAD)

fail=0
check() { # want event prev head prev_status [prev_event, default push]
    got=$(CI_PIPELINE_EVENT=$2 CI_PREV_COMMIT_SHA=$3 CI_COMMIT_SHA=$4 CI_PREV_PIPELINE_STATUS=$5 \
        CI_PREV_PIPELINE_EVENT=${6-push} ci/changes.sh)
    if [ "$got" != "$1" ]; then
        echo "changes.sh event=$2 prev_status=$5 prev_event=${6-push}: got $got, want $1" >&2
        fail=1
    fi
}
check false push "$base" "$docs" success
check true push "$base" "$docs" killed
check true push "$base" "$docs" failure
check true push "$base" "$docs" ""
check true push "$docs" "$code" success
check true push "" "$docs" success
check true push 0000000000000000000000000000000000000000 "$docs" success
check true manual "$base" "$docs" success
# The previous pipeline was a manual run (NERVA_RUN=jepsen) that succeeded: it ran no CI workflow.
check true push "$base" "$docs" success manual
check true push "$base" "$docs" success cron
check true push "$base" "$docs" success ""
exit $fail
