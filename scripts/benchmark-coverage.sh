#!/usr/bin/env bash
# benchmark-coverage.sh — reproduce Table 2 of Cadar et al. 2008 by running
# KLEE on every coreutils tool in the build tree and measuring gcov line
# coverage.
#
# Three phases:
#   1a. Standard KLEE run (no failure injection). Parallel; skips any tool
#       that already has ktests under build/klee-out/<tool>/.
#   1b. --max-fail 1 run (syscall failure injection). Parallel; skips any
#       tool that already has ktests under build/klee-out-fail/<tool>/.
#   2.  klee-replay + gcov, serial. Replays both phase-1 outputs into the
#       same gcov session, producing Base+Fail unioned coverage.
#
# Incremental: re-running the script is safe. Existing ktests from prior
# runs are reused; only missing outputs are regenerated.
#
# Usage:
#   ./scripts/benchmark-coverage.sh                   # default 10 jobs, 60 min
#   ./scripts/benchmark-coverage.sh <jobs> <minutes>
#   JOBS=4 MINUTES=10 ./scripts/benchmark-coverage.sh
#   NO_FAIL=1 ./scripts/benchmark-coverage.sh         # skip the fail-injection pass
#
# Outputs (under results/):
#   coverage.csv           per-tool line/branch coverage
#   batch-<TIMESTAMP>.log  full stdout/stderr, and the aggregate summary

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-$REPO/build}"
JOBS="${JOBS:-${1:-10}}"
MINUTES="${MINUTES:-${2:-60}}"

SRC_DIR="$WORK/coreutils-6.11/obj-llvm/src"
if [ ! -d "$SRC_DIR" ]; then
    echo "error: no build tree at $SRC_DIR — run ./scripts/setup.sh first" >&2
    exit 1
fi

# Every .bc in the build except vdir (wrapper for `ls -l -b`, per paper fn 1).
TOOLS=$(ls "$SRC_DIR"/*.bc | xargs -n1 basename -s .bc | grep -vx 'vdir' | sort)
N=$(printf '%s\n' "$TOOLS" | wc -l)

RESULTS="$REPO/results"
mkdir -p "$RESULTS"
TS=$(date +%Y%m%d-%H%M%S)
LOG="$RESULTS/batch-$TS.log"
CSV="$RESULTS/coverage.csv"

log() { printf '[%s] %s\n' "$(date -Is)" "$*" | tee -a "$LOG"; }

log "benchmark: $N tools, $JOBS parallel, ${MINUTES} min each"
log "log: $LOG"
log "csv: $CSV"

# Emit only the tools that lack ktests in the given output dir (so xargs
# doesn't redo work from previous runs).
missing_in() {
    local subdir="$1"
    for t in $TOOLS; do
        if ! ls "$WORK/$subdir/$t"/test*.ktest >/dev/null 2>&1; then
            printf '%s\n' "$t"
        fi
    done
}

log "phase 1a: standard KLEE run (parallel, skipping existing)"
todo=$(missing_in "klee-out")
n_todo=$(printf '%s' "$todo" | grep -c . || true)
log "  $n_todo tools to run (others already have ktests)"
if [ "$n_todo" -gt 0 ]; then
    printf '%s\n' "$todo" \
        | xargs -n1 -P "$JOBS" -I{} "$REPO/scripts/run-klee.sh" {} "$MINUTES" \
            >> "$LOG" 2>&1 \
        || log "phase 1a: some tools exited non-zero (continuing)"
fi
log "phase 1a: done"

if [ -z "${NO_FAIL:-}" ]; then
    log "phase 1b: --max-fail 1 run (parallel, skipping existing)"
    todo=$(missing_in "klee-out-fail")
    n_todo=$(printf '%s' "$todo" | grep -c . || true)
    log "  $n_todo tools to run (others already have ktests)"
    if [ "$n_todo" -gt 0 ]; then
        printf '%s\n' "$todo" \
            | xargs -n1 -P "$JOBS" -I{} "$REPO/scripts/run-klee.sh" {} "$MINUTES" 1 \
                >> "$LOG" 2>&1 \
            || log "phase 1b: some tools exited non-zero (continuing)"
    fi
    log "phase 1b: done"
else
    log "phase 1b: skipped (NO_FAIL=1)"
fi

log "phase 2: gcov replay (serial)"
echo "tool,lines_pct,lines_total,branches_pct,branches_total" > "$CSV"
for t in $TOOLS; do
    out=$("$REPO/scripts/measure-coverage.sh" "$t" 2>&1 || true)
    printf '\n=== %s ===\n%s\n' "$t" "$out" >> "$LOG"
    lp=$(printf '%s\n' "$out" | awk -F'[:%]' '/^Lines executed/    {gsub(/ /,"",$2); print $2}')
    lt=$(printf '%s\n' "$out" | awk -F'of '   '/^Lines executed/    {gsub(/ /,"",$2); print $2}')
    bp=$(printf '%s\n' "$out" | awk -F'[:%]' '/^Branches executed/ {gsub(/ /,"",$2); print $2}')
    bt=$(printf '%s\n' "$out" | awk -F'of '   '/^Branches executed/ {gsub(/ /,"",$2); print $2}')
    printf '%s,%s,%s,%s,%s\n' "$t" "$lp" "$lt" "$bp" "$bt" >> "$CSV"
done
log "phase 2: done"

# Aggregates matching the paper's Table 2 columns. Uses external sort instead
# of gawk's asort() so it works under mawk.
sorted=$(awk -F, 'NR>1 && $2!="" {print $2+0}' "$CSV" | sort -n)
if [ -z "$sorted" ]; then
    log "no successful tools — skipping aggregates"
else
    n=$(printf '%s\n' "$sorted" | wc -l)
    mean=$(printf '%s\n' "$sorted" | awk '{s+=$1} END {printf "%.2f", s/NR}')
    mid=$(( (n + 1) / 2 ))
    if [ $((n % 2)) -eq 1 ]; then
        median=$(printf '%s\n' "$sorted" | sed -n "${mid}p")
    else
        lo=$(printf '%s\n' "$sorted" | sed -n "${mid}p")
        hi=$(printf '%s\n' "$sorted" | sed -n "$((mid+1))p")
        median=$(printf '%s %s\n' "$lo" "$hi" | awk '{printf "%.2f", ($1+$2)/2}')
    fi
    agg=$(awk -F, 'NR>1 && $2!="" {c+=$2*$3/100; t+=$3} END {if (t>0) printf "%.2f", c/t*100}' "$CSV")
    c100=$(printf '%s\n' "$sorted" | awk '$1+0 >= 99.9' | wc -l)
    c90=$(printf '%s\n'  "$sorted" | awk '$1+0 >= 90'   | wc -l)
    {
        echo "=== Table 2 reproduction ==="
        printf '  successful tools:          %s / %s\n' "$n" "$N"
        printf '  aggregate (weighted) cov:  %s %%\n'   "$agg"
        printf '  mean per-tool coverage:    %s %%\n'   "$mean"
        printf '  median per-tool coverage:  %s %%\n'   "$median"
        printf '  tools at 100%%:             %s\n'     "$c100"
        printf '  tools at >= 90%%:           %s\n'     "$c90"
    } | tee -a "$LOG"
fi

log "done"
