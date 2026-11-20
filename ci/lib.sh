# shellcheck shell=bash
# Sourced by ci/*.sh. What a CI script needs from the system running it, in one place, so the
# scripts run the same under GitHub Actions, Woodpecker or a shell (ops/ci/README.md, "Nerva on Woodpecker").
#
#   ci_error MESSAGE      an error line: an annotation on GitHub, `error: ...` elsewhere
#   ci_warning MESSAGE    the same for a warning
#   ci_mask VALUE         hides VALUE in GitHub's log; elsewhere VALUE is remembered for ci_redact
#   ci_redact             a filter that replaces every masked value (and its first 16 characters)
#                         in its input with ***: Woodpecker masks only the secrets it holds, so
#                         anything that may print a masked value goes through it
#   ci_summary            appends stdin to the run's summary: GitHub's step summary, else the log
#   ci_event              push | pull_request | manual | cron | other

ci_error() {
    if [ "${GITHUB_ACTIONS:-}" = true ]; then echo "::error::$*"; else echo "error: $*" >&2; fi
}

ci_warning() {
    if [ "${GITHUB_ACTIONS:-}" = true ]; then echo "::warning::$*"; else echo "warning: $*" >&2; fi
}

CI_MASKED=()
ci_mask() {
    if [ "${GITHUB_ACTIONS:-}" = true ]; then echo "::add-mask::$1"; else CI_MASKED+=("$1"); fi
}

# Values are hex (a key from `openssl rand -hex`); anything else is refused, as sed's pattern
# would otherwise need escaping.
ci_redact() {
    local script=() v
    for v in ${CI_MASKED[@]+"${CI_MASKED[@]}"}; do
        [[ "$v" =~ ^[0-9A-Fa-f]{16,}$ ]] || { ci_error "ci_redact: a masked value must be at least 16 hex characters"; return 1; }
        script+=(-e "s/${v}/***/g" -e "s/${v:0:16}/***/g")
    done
    if [ "${#script[@]}" -eq 0 ]; then cat; else sed -u "${script[@]}"; fi
}

ci_summary() {
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        cat >> "$GITHUB_STEP_SUMMARY"
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
