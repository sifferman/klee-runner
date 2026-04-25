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

# Self-heal: the KLEE container occasionally strips mode bits on $WORK
# subdirs to 000 on WSL, which silently breaks `[ -d ... ]` traversal in
# Phase 2 and produces an almost-empty CSV. Restore traverse + read perms
# before doing anything else. -X means "execute bit only on dirs", so this
# doesn't make every regular file executable.
chmod -R u+rwX "$WORK" 2>/dev/null || true

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

log "phase 2: gcov replay (serial, base + combined per tool)"
# Wide CSV so the plot can stack Base under Base+Fail. lines_total and
# branches_total are mode-independent (same source file), so one column each.
echo "tool,lines_pct_base,lines_pct_combined,lines_total,branches_pct_base,branches_pct_combined,branches_total" > "$CSV"

# Extract "81.42" from "Lines executed:81.42% of 113"
extract_pct()   { awk -F'[:%]' '/^Lines executed/    {gsub(/ /,"",$2); print $2}'; }
extract_lines() { awk -F'of '  '/^Lines executed/    {gsub(/ /,"",$2); print $2}'; }
extract_bpct()  { awk -F'[:%]' '/^Branches executed/ {gsub(/ /,"",$2); print $2}'; }
extract_btot()  { awk -F'of '  '/^Branches executed/ {gsub(/ /,"",$2); print $2}'; }

for t in $TOOLS; do
    out_base=$(MODE=base     "$REPO/scripts/measure-coverage.sh" "$t" 2>&1 || true)
    out_comb=$(MODE=combined "$REPO/scripts/measure-coverage.sh" "$t" 2>&1 || true)
    printf '\n=== %s (base) ===\n%s\n=== %s (combined) ===\n%s\n' \
        "$t" "$out_base" "$t" "$out_comb" >> "$LOG"

    lp_b=$(printf '%s\n' "$out_base" | extract_pct)
    lp_c=$(printf '%s\n' "$out_comb" | extract_pct)
    lt=$(  printf '%s\n' "$out_comb" | extract_lines)
    bp_b=$(printf '%s\n' "$out_base" | extract_bpct)
    bp_c=$(printf '%s\n' "$out_comb" | extract_bpct)
    bt=$(  printf '%s\n' "$out_comb" | extract_btot)

    printf '%s,%s,%s,%s,%s,%s,%s\n' "$t" "$lp_b" "$lp_c" "$lt" "$bp_b" "$bp_c" "$bt" >> "$CSV"
done
log "phase 2: done"

# Aggregate/median/mean for both modes, side-by-side. Uses external sort (no
# gawk-isms) so it runs under mawk.
summarize() {
    local col="$1" total_col="$2" label="$3"
    local sorted
    sorted=$(awk -F, -v c="$col" 'NR>1 && $c!="" {print $c+0}' "$CSV" | sort -n)
    [ -z "$sorted" ] && { printf '  %-40s no data\n' "$label"; return; }
    local n mean med agg c100 c90 mid lo hi
    n=$(printf '%s\n' "$sorted" | wc -l)
    mean=$(printf '%s\n' "$sorted" | awk '{s+=$1} END {printf "%.2f", s/NR}')
    mid=$(( (n + 1) / 2 ))
    if [ $((n % 2)) -eq 1 ]; then
        med=$(printf '%s\n' "$sorted" | sed -n "${mid}p")
    else
        lo=$(printf '%s\n' "$sorted" | sed -n "${mid}p")
        hi=$(printf '%s\n' "$sorted" | sed -n "$((mid+1))p")
        med=$(printf '%s %s\n' "$lo" "$hi" | awk '{printf "%.2f", ($1+$2)/2}')
    fi
    agg=$(awk -F, -v c="$col" -v tc="$total_col" 'NR>1 && $c!="" {cv+=$c*$tc/100; tt+=$tc} END {if (tt>0) printf "%.2f", cv/tt*100}' "$CSV")
    c100=$(printf '%s\n' "$sorted" | awk '$1+0 >= 99.9' | wc -l)
    c90=$( printf '%s\n' "$sorted" | awk '$1+0 >= 90'   | wc -l)
    printf '  %-40s overall=%s%%  median=%s%%  mean=%s%%  100%%=%s  >=90%%=%s  (n=%s)\n' \
        "$label" "$agg" "$med" "$mean" "$c100" "$c90" "$n"
}

{
    echo "=== Table 2 reproduction ==="
    summarize 2 4 "standard run (Base):"
    summarize 3 4 "with --max-fail 1 (Base+Fail):"
} | tee -a "$LOG"

log "done"
