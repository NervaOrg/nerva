#!/usr/bin/env bash
# One Jepsen run on demand (R1 slice 2, P215): checks the arguments, builds a ReleaseSafe `nerva`
# (or the teeth build), runs the suite's own checkers, then tests/jepsen/run.sh with a fresh
# cluster key, and packs the store unless the key leaked into it. The same under jepsen.yml
# (GitHub's hosted runner) and .woodpecker/jepsen.yaml (the project's machine). Run from the
# repository root after the pinned Zig is installed. Needs Docker, JDK 21 on PATH, gnuplot and
# ssh-keygen. Exits as Jepsen does: 0 valid, 1 invalid, 2 unknown, 255 a crash.
#
#   ARGS                  `lein run` arguments: `test ...`, --time-limit at most 1200
#                         (default: test --workload bank --nemesis kill,partition --time-limit 300)
#   TEETH                 true: the commit-key-deduplication-off build (-Dtest-commit-keys=off)
#   JEPSEN_LAZYFS_PATCH   no: the stock-LazyFS canary (P242j), which must fail
#   JEPSEN_OUT            where jepsen-store.tar.gz and jepsen-memory* go
#                         (default: $RUNNER_TEMP/jepsen-out, else $TMPDIR/jepsen-out)
set -euo pipefail
. "$(dirname "$0")/lib.sh"

ARGS="${ARGS:-test --workload bank --nemesis kill,partition --time-limit 300}"
TEETH="${TEETH:-false}"
export JEPSEN_LAZYFS_PATCH="${JEPSEN_LAZYFS_PATCH:-yes}"
out="${JEPSEN_OUT:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/jepsen-out}"
mkdir -p "$out"

# `args` goes to a shell word-split, so only a plain alphabet gets through, and only `test`:
# `test-all` multiplies the time limit by the number of tests, and the job has one hour.
if [[ "$ARGS" == *$'\n'* || "$ARGS" == *$'\r'* ]]; then
    ci_error "args must be one line: a newline would drop everything after it"
    exit 1
fi
if ! [[ "$ARGS" =~ ^test([[:space:]]+[A-Za-z0-9,._=-]+)*$ ]]; then
    ci_error "args must be 'test' and options of letters, digits and , . _ = -: '$ARGS'"
    exit 1
fi
[[ "$TEETH" == true || "$TEETH" == false ]] || { ci_error "TEETH must be true or false, not '$TEETH'"; exit 1; }
[[ "$JEPSEN_LAZYFS_PATCH" == yes || "$JEPSEN_LAZYFS_PATCH" == no ]] ||
    { ci_error "JEPSEN_LAZYFS_PATCH must be yes or no, not '$JEPSEN_LAZYFS_PATCH'"; exit 1; }
limit=60
read -r -a words <<< "$ARGS"
lazyfs_fault=false
strict=false
for i in "${!words[@]}"; do
    case "${words[$i]}" in
    --lazyfs-strict-sync | --lazyfs-strict-sync=*) strict=true ;;
    --nemesis | --nemesis=*)
        spec=${words[$i]#--nemesis=}
        [[ "${words[$i]}" == --nemesis ]] && spec=${words[$((i + 1))]:-}
        # tools.cli keeps only the last --nemesis, so only the last one counts (#257).
        lazyfs_fault=false
        [[ ",$spec," == *,lose-unfsynced-writes,* ]] && lazyfs_fault=true
        ;;
    --test-count | --test-count=*)
        ci_error "--test-count is refused: the 1200 s --time-limit check cannot bound a multiplied run"
        exit 1
        ;;
    --lazyfs-all-nodes | --lazyfs-all-nodes=*)
        # A hosted runner's 16 GB leaves about 0.4 GiB free with LazyFS on all 5 nodes (P242j);
        # the project's own machine has the memory.
        if [ "${GITHUB_ACTIONS:-}" = true ]; then
            ci_error "NRV-E0607: --lazyfs-all-nodes is refused on a hosted runner: LazyFS on all 5 nodes leaves its 16 GB about 0.4 GiB free (P242j). Run it on Woodpecker (NERVA_RUN=jepsen) or the R1 host (ops/jepsen)"
            exit 1
        fi
        ;;
    --time-limit) limit=${words[$((i + 1))]:-} ;;
    --time-limit=*) limit=${words[$i]#--time-limit=} ;;
    esac
done
# The canary (P242j) is a run that must fail: without the fault and strict mode it is green and
# blind (#257).
if [[ "$JEPSEN_LAZYFS_PATCH" == no ]] && { [[ $lazyfs_fault != true ]] || [[ $strict != true ]]; }; then
    ci_error "NRV-E0607: unpatched-lazyfs is a canary: args must name --nemesis lose-unfsynced-writes and --lazyfs-strict-sync, or the run is green and tests nothing"
    exit 1
fi
if ! [[ "$limit" =~ ^[0-9]+$ ]] || ((limit > 1200)); then
    ci_error "--time-limit must be a number of seconds, at most 1200, not '$limit'"
    exit 1
fi
echo "Jepsen \`$ARGS\` at \`$(git rev-parse HEAD)\` (teeth: $TEETH, LazyFS patch: $JEPSEN_LAZYFS_PATCH)" | ci_summary

# The teeth build exists from slice 1 (-Dtest-commit-keys=off); until it does, asking for it fails
# here, loudly, and not by running the release build as if it were the teeth.
if [[ "$TEETH" == true ]]; then
    if ! grep -q 'test-commit-keys' build.zig; then
        ci_error "teeth needs -Dtest-commit-keys=off (R1 slice 1), which this commit's build.zig lacks"
        exit 1
    fi
    ./zig/zig build -Drelease -Dtest-commit-keys=off -p zig-out-teeth
    nerva=$PWD/zig-out-teeth/bin/nerva
else
    ./zig/zig build -Drelease
    nerva=$PWD/zig-out/bin/nerva
fi
"$nerva" version
command -v gnuplot >/dev/null || { ci_error "no gnuplot: without it Jepsen's graphs, and so the result, are :unknown"; exit 1; }
timeout 60 docker info --format 'Docker {{.ServerVersion}}, {{.NCPU}} CPUs, {{.MemTotal}} bytes'

# The suite's checkers (lein test), with Leiningen 2.12.0, sha256-checked (tools.sh).
(
    cd tests/jepsen
    lein=$(./tools.sh)
    LEIN_JAR="$PWD/.tools/leiningen-standalone.jar" "$lein" test
)

# A fresh cluster key for this run (P102), never a stored secret: nothing else ever knows it.
# Never printed (masked on GitHub as well), and searched for in the store before it is packed.
NERVA_CLUSTER_KEY=$(openssl rand -hex 32)
ci_mask "$NERVA_CLUSTER_KEY"
export NERVA_CLUSTER_KEY
# The memory record (P242i): `free -m` at the start and the end, and the lowest MemAvailable seen
# (sampled every 5 s) in between: meminfo, RSS per command, the top processes and container
# cgroups (tests/jepsen/memsample.sh, P242j).
free -m
tests/jepsen/memsample.sh "$out/jepsen-memory.log" "$out/jepsen-memory-low.txt" &
sampler=$!
rc=0
tests/jepsen/run.sh "$nerva" "${words[@]}" || rc=$?
kill "$sampler" 2>/dev/null || true
free -m
echo "memory: the sample at the lowest MemAvailable"
cat "$out/jepsen-memory-low.txt" || true

# Searches case-insensitively, for the key and for its first 16 hex characters. A store that
# holds it is never packed, so never shared.
if [[ -d tests/jepsen/store ]]; then
    if grep -rliF -e "$NERVA_CLUSTER_KEY" -e "${NERVA_CLUSTER_KEY:0:16}" tests/jepsen/store; then
        ci_error "the cluster key is in the store (files above): it is not packed; do not share it"
        exit 1
    fi
    echo "No file in store/ holds the run's cluster key" | ci_summary
    tar -czf "$out/jepsen-store.tar.gz" -C tests/jepsen store
    echo "store: $out/jepsen-store.tar.gz"
fi
exit "$rc"
