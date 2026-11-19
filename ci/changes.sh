#!/usr/bin/env bash
# Prints `true` when this run's change can affect what CI proves, `false` when it is Markdown
# that no build or test reads (.github/scripts/docs_only.sh, N68). For a push outside GitHub
# Actions (Woodpecker), the change is CI_PREV_COMMIT_SHA..CI_COMMIT_SHA. Fails closed: anything
# else, a new branch, or a previous commit that cannot be fetched, is `true`. GitHub Actions'
# pull requests are classified by ci.yml's `changes` job, from the API.
set -uo pipefail

prev="${CI_PREV_COMMIT_SHA:-}"
head="${CI_COMMIT_SHA:-HEAD}"
if [ "${CI_PIPELINE_EVENT:-}" != push ] || [ -z "$prev" ] || [ -z "${prev//0/}" ]; then
    echo true; exit 0
fi
if ! git cat-file -e "$prev^{commit}" 2>/dev/null; then
    git fetch -q --depth=1 origin "$prev" 2>/dev/null || { echo true; exit 0; }
fi
files=$(git diff --name-only "$prev" "$head" 2>/dev/null) || { echo true; exit 0; }
printf '%s\n' "$files" | .github/scripts/docs_only.sh
