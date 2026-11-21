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
#   ci_run_timed JOB SECONDS CMD...
#                         runs CMD under `timeout`; NRV-E1215 if it ran past SECONDS (exit 124, or
#                         137 when it ignored the TERM and was killed 60 s later, CI_KILL_AFTER)
#                         and SECONDS have really passed; NRV-E1222 for a SIGKILL before that; the
#                         message names CI_TIMEOUT_KNOB (default CI_STEP_MINUTES) as what raises it
#   ci_step_run_with_tests JOB TEST_SECONDS JOB_SECONDS TESTS_ARRAY JOB_ARRAY
#                         the tail of a Woodpecker step (ci/woodpecker_step.sh); TESTS_ARRAY and
#                         JOB_ARRAY name arrays holding the commands. For check-scripts it runs the
#                         tests first (as the step's user, root, bounded by TEST_SECONDS) and then
#                         the job with CI_SCRIPTS_TESTED=1 (so ci/job.sh skips its own run of them);
#                         any other job runs alone, with CI_SCRIPTS_TESTED unset. Returns the job's
#                         status, else the tests' status: either failing fails the step. Both run
#                         with the step's lock descriptors (6 to 9) closed.

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
        [[ "$v" =~ ^[0-9A-Fa-f]{16,}$ ]] || { ci_error "NRV-B1201: ci_redact: a masked value must be at least 16 hex characters (a bug in the script that masked it)"; return 1; }
        script+=(-e "s/${v}/***/gI" -e "s/${v:0:16}/***/gI")
    done
    if [ "${#script[@]}" -eq 0 ]; then cat; else sed -u "${script[@]}"; fi
}

ci_run_timed() {
    local job="$1" seconds="$2" status=0 limit start="$SECONDS"
    shift 2
    timeout --kill-after="${CI_KILL_AFTER:-60}" "$seconds" "$@" || status=$?
    if [ "$status" = 137 ] && [ $((SECONDS - start)) -lt "$seconds" ]; then
        # SIGKILL well before the limit: not our timeout (it kills only after the limit plus the
        # grace period), so the kernel's OOM killer or someone's kill -9.
        ci_error "NRV-E1222: $job was killed by SIGKILL after $((SECONDS - start)) s, before its limit of $seconds s: possibly the OOM killer; check dmesg or journalctl -k"
    elif [ "$status" = 124 ] || [ "$status" = 137 ]; then
        [ $((SECONDS - start)) -ge "$seconds" ] || return "$status" # the command's own exit 124
        limit="$seconds seconds"
        [ $((seconds % 60)) != 0 ] || limit="$((seconds / 60)) minutes"
        ci_error "NRV-E1215: $job ran past its $limit and was stopped: a hung job, or a limit too short for this box; ${CI_TIMEOUT_KNOB:-CI_STEP_MINUTES} raises it for a run"
    fi
    return "$status"
}

ci_step_run_with_tests() {
    local job="$1" test_seconds="$2" job_seconds="$3" tests_status=0 status=0
    local -n tests_cmd="$4" job_cmd="$5"
    if [ "$job" = check-scripts ]; then
        CI_TIMEOUT_KNOB=CI_SCRIPTS_TEST_MINUTES ci_run_timed "$job's ci_test.sh, as root" "$test_seconds" "${tests_cmd[@]}" 6>&- 7>&- 8>&- 9<&- || tests_status=$?
        export CI_SCRIPTS_TESTED=1
    else
        unset CI_SCRIPTS_TESTED
    fi
    ci_run_timed "$job" "$job_seconds" "${job_cmd[@]}" 6>&- 7>&- 8>&- 9<&- || status=$?
    [ "$status" != 0 ] || status=$tests_status
    return "$status"
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
