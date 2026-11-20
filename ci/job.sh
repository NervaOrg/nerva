#!/usr/bin/env bash
# One CI job, the same under GitHub Actions (.github/workflows/ci.yml), Woodpecker (.woodpecker/)
# or a shell. Run from the repository root, after ci/install_zig.sh.
#
#   ci/job.sh check                 typecheck, format, the scripts' own tests, declared views: the
#                                   three below in turn (GitHub runs it whole; Woodpecker, the parts
#                                   side by side, as the package repositories' tests alone take
#                                   20 minutes)
#   ci/job.sh check-code            typecheck, format, the quickstart loop, declared views
#   ci/job.sh check-scripts         the release, perf, fleet, Jepsen and CI scripts' tests
#   ci/job.sh check-packages        the package repositories' tests (the longest of the scripts')
#   ci/job.sh integration           three real replicas (~3.5 GiB of disk)
#   ci/job.sh api                   the JSON API against a model
#   ci/job.sh releases              mixed releases
#   ci/job.sh targets               targets-check, then targets-build
#   ci/job.sh targets-check         every release target type-checks (Debug)
#   ci/job.sh targets-build         every release target builds as release.yml builds it
#                                   (GitHub: not on a pull request; Woodpecker: on main only)
#   ci/job.sh unit                  unit tests
#   ci/job.sh fuzz-smoke            every fuzzer at its smoke size
#   ci/job.sh demo <file>           one demo under crashes (tests/demo/<file>)
#   ci/job.sh demo-r4 | demo-r5     a milestone's demo
#   ci/job.sh vopr <seed|random>    one VOPR seed, Debug (a pull request's)
#   ci/job.sh vopr-main <lane>      main's VOPR, ReleaseSafe: `fixed` (1, 2, 5) or random-N (6 min)
#   ci/job.sh fuzz-long <fuzzer>    one fuzzer on random seeds for $MINUTES (default 120, at most 300)
#   ci/job.sh vopr-long <sm>-<lane> the VOPR of state machine <sm> (nerva, testing) likewise
#   ci/job.sh jepsen                one Jepsen run ($ARGS, $TEETH: ci/jepsen.sh)
#
# Every job's commands are here and nowhere else; the CI systems' files only say where and when.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

job="${1:-}"
[ -n "$job" ] || { ci_error "NRV-E1208: usage: ci/job.sh <job> [arg]"; exit 2; }
arg="${2:-}"
targets=(x86_64-linux aarch64-linux x86_64-macos aarch64-macos)
demos_expected="canvas_chaos.py seats_chaos.py "

# Every release target compiles (#276): a Debug check of each (P285), then, except on a pull
# request, each built as release.yml builds it. Woodpecker never sees a pull request, so there the
# builds run only for a push to main (a branch's pipeline would build four releases per push).
targets_check() {
    for t in "${targets[@]}"; do ./zig/zig build check -Dtarget="$t"; done
}

targets_build() {
    if [ "$(ci_event)" = pull_request ] || { [ -n "${CI_PIPELINE_EVENT:-}" ] && { [ "$CI_PIPELINE_EVENT" != push ] || [ "${CI_COMMIT_BRANCH:-}" != main ]; }; }; then
        echo "release builds: skipped (not a push to main)"
        return 0
    fi
    for t in "${targets[@]}"; do ./zig/zig build -Drelease -Dtarget="$t"; done
}

check_code() {
    ./zig/zig build check
    ./zig/zig build test:fmt
    .github/scripts/docs_only_test.sh
    scripts/quickstart_loop_test.sh # its refusals, NRV-E0741 and NRV-E0742
    ./zig/zig build test:views
}

check_scripts() {
    # The release scripts: the bill of materials (N63) and the refusals (NRV-E1112 to E1117,
    # E1130 to E1138, E1152, E1164). Needs ci/install_repo_tools.sh first.
    ci/changes_test.sh # Woodpecker's docs-only skip, only over a pipeline that succeeded
    ci/ci_test.sh # the CI scripts' refusals, NRV-E1201 to E1221 but E1203, E1209 and E1210, NRV-B1201, W1201 and W1202
    python3 .github/scripts/test_sbom.py
    python3 .github/scripts/test_release_check.py
    python3 .github/scripts/test_mac_sign.py
    python3 -I .github/scripts/test_site_release.py
    python3 -I .github/scripts/test_release_finish.py
    python3 -I .github/scripts/test_r2.py
    python3 -I .github/scripts/test_site_build.py
    python3 -I .github/scripts/test_repos_alarm.py
    # The nightly perf scripts, the simulation fleet's and Jepsen nightly's reporters (no network).
    python3 perf/nightly/test_compare.py
    python3 perf/nightly/test_file_issue.py
    python3 ops/sim-fleet/test_sim_fleet.py
    python3 -I ops/jepsen/test_jepsen_report.py
}

check_packages() {
    python3 -I .github/scripts/test_package_repos.py
}

case "$job" in
check)
    check_code
    check_scripts
    check_packages
    ;;
check-code) check_code ;;
check-scripts) check_scripts ;;
check-packages) check_packages ;;
integration) ./zig/zig build test:integration ;;
api) ./zig/zig build test:api ;;
releases) ./zig/zig build test:release ;;
targets-check) targets_check ;;
targets-build) targets_build ;;
targets)
    targets_check
    targets_build
    ;;
unit)
    # `benchmark.perf: usage example` skips itself where perf_event_open is denied (UPSTREAM.md).
    ./zig/zig build test:unit
    ;;
fuzz-smoke)
    # `lsm_segmented_array` logs "too slow for the smoke mode" in Debug: a warning, not a failure.
    ./zig/zig build fuzz -- smoke
    ;;
demo)
    [ -n "$arg" ] || { ci_error "NRV-E1208: usage: ci/job.sh demo <file>"; exit 2; }
    # The CI files list the demos one by one; they must be the ones test:demo runs (build.zig).
    listed=$(grep -o '"[a-z_]*_chaos\.py"' build.zig | tr -d '"' | sort | tr '\n' ' ')
    if [ "$listed" != "$demos_expected" ]; then
        ci_error "NRV-E1208: build.zig's test:demo runs '$listed'; update demos_expected in ci/job.sh, ci.yml's demo matrix and .woodpecker/demo.yaml"
        exit 1
    fi
    ./zig/zig build -Drelease
    python3 "tests/demo/$arg" zig-out/bin/nerva --seconds=75
    ;;
demo-r4 | demo-r5) ./zig/zig build -Drelease "$job" ;;
vopr)
    # A failure replays exactly with `./zig/zig build vopr -- <seed>`.
    seed="$arg"
    [ -n "$seed" ] || { ci_error "NRV-E1208: usage: ci/job.sh vopr <seed|random>"; exit 2; }
    if [ "$seed" = random ]; then seed=$(od -An -N8 -tu8 /dev/urandom | tr -d ' '); fi
    echo "VOPR seed: $seed"
    echo "### VOPR seed \`$seed\`" | ci_summary
    ./zig/zig build vopr -- "$seed"
    ;;
vopr-main)
    # A failure replays exactly with `./zig/zig build -Drelease vopr -- <seed>`.
    case "$arg" in
    fixed)
        for seed in 1 2 5; do
            echo "VOPR seed: $seed"
            echo "### VOPR seed \`$seed\` (ReleaseSafe)" | ci_summary
            ./zig/zig build -Drelease vopr -- "$seed"
        done
        ;;
    random-*) .github/scripts/fuzz_loop.sh vopr nerva 6 ;;
    *) ci_error "NRV-E1208: usage: ci/job.sh vopr-main fixed|random-N"; exit 2 ;;
    esac
    ;;
jepsen) exec ci/jepsen.sh ;;
fuzz-long | vopr-long)
    # Searches, where fuzz-smoke and vopr only check (N59, fuzz.yml). A failure prints its seed
    # and the command that replays it exactly.
    minutes="${MINUTES:-120}"
    [[ "$minutes" =~ ^[1-9][0-9]*$ ]] || { ci_error "NRV-E1208: MINUTES must be a whole number, not '$minutes'"; exit 2; }
    ((minutes <= 300)) || minutes=300
    [ -n "$arg" ] || { ci_error "NRV-E1208: usage: ci/job.sh $job <fuzzer | state machine-lane>"; exit 2; }
    if [ "$job" = fuzz-long ]; then
        .github/scripts/fuzz_loop.sh fuzz "$arg" "$minutes"
    else
        .github/scripts/fuzz_loop.sh vopr "${arg%-*}" "$minutes"
    fi
    ;;
*) ci_error "NRV-E1208: unknown job '$job'"; exit 2 ;;
esac
