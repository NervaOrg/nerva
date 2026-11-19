# Sourced by ci/*.sh. What a CI script needs from the system running it, in one place, so the
# scripts run the same under GitHub Actions, Woodpecker or a shell (P-ci-portable).
#
#   ci_error MESSAGE      an error line: an annotation on GitHub, `error: ...` elsewhere
#   ci_warning MESSAGE    the same for a warning
#   ci_summary            appends stdin to the run's summary: GitHub's step summary, else
#                         $CI_SUMMARY if set, else the log
#   ci_event              push | pull_request | manual | cron | other
#   ci_branch             the branch pushed or targeted, or empty
#   ci_on_main_push       true when this run is a push to main (a release's call of ci.yml is one)

ci_error() {
    if [ "${GITHUB_ACTIONS:-}" = true ]; then echo "::error::$*"; else echo "error: $*" >&2; fi
}

ci_warning() {
    if [ "${GITHUB_ACTIONS:-}" = true ]; then echo "::warning::$*"; else echo "warning: $*" >&2; fi
}

ci_summary() {
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        cat >> "$GITHUB_STEP_SUMMARY"
    elif [ -n "${CI_SUMMARY:-}" ]; then
        cat >> "$CI_SUMMARY"
    else
        sed 's/^/summary: /'
    fi
}

ci_event() {
    local e="${GITHUB_EVENT_NAME:-${CI_PIPELINE_EVENT:-}}"
    case "$e" in
        push | pull_request) echo "$e" ;;
        pull_request_target | pull_request_closed) echo pull_request ;;
        workflow_dispatch | manual) echo manual ;;
        schedule | cron) echo cron ;;
        # A release's call of ci.yml (workflow_call) reports its caller's event, a push.
        *) echo other ;;
    esac
}

ci_branch() {
    if [ "${GITHUB_ACTIONS:-}" = true ]; then
        case "${GITHUB_REF:-}" in refs/heads/*) echo "${GITHUB_REF#refs/heads/}" ;; esac
    else
        echo "${CI_COMMIT_BRANCH:-}"
    fi
}

ci_on_main_push() {
    [ "$(ci_event)" = push ] && [ "$(ci_branch)" = main ]
}
