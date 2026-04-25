#!/usr/bin/env bash
# benchmark-tinyexpr.sh — run KLEE on tinyexpr (a small recursive-descent
# math-expression parser) and report line coverage.
#
# Why tinyexpr: it's a category of code the OSDI'08 paper didn't cover
# (a hand-written parser library), small enough (~800 LOC) to plausibly
# saturate coverage in a few minutes, and structurally KLEE-friendly
# (no generated lexer tables, no network, no threads).
#
# We test the parser only, via te_compile, NOT te_interp/te_eval — KLEE has
# limited symbolic floating-point support and the eval path is full of FP.
# Calling te_compile alone exercises the parser end-to-end (tokenization,
# precedence climbing, error recovery) without ever performing FP arithmetic
# on symbolic data.
#
# Usage:
#   ./scripts/benchmark-tinyexpr.sh                        # 5 min, 32-char input
#   ./scripts/benchmark-tinyexpr.sh <minutes>
#   MAX_ARG_CHARS=64 ./scripts/benchmark-tinyexpr.sh 10
#
# Outputs:
#   build/tinyexpr/                  build artifacts (gcov + bitcode)
#   build/klee-out/tinyexpr/         KLEE output
#   results/tinyexpr-<TS>.log        full stdout/stderr
#   results/tinyexpr.c.gcov          gcov line-by-line annotated source
#   results/tinyexpr-coverage.txt    one-line summary

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-$REPO/build}"
SRC="$REPO/external/tinyexpr"
IMAGE="${KLEE_IMAGE:-klee/klee@sha256:05e56e17d88ed02f2872ec2ec78e7c4282d0328dc203d0a5f05cc1d458688d8f}"
MINUTES="${1:-5}"
MAX_ARG_CHARS="${MAX_ARG_CHARS:-32}"

if [ ! -f "$SRC/tinyexpr.c" ]; then
    echo "error: tinyexpr source not found at $SRC" >&2
    echo "       initialize the submodule: git submodule update --init external/tinyexpr" >&2
    exit 1
fi

BUILD_DIR="$WORK/tinyexpr"
mkdir -p "$BUILD_DIR"
cp -u "$SRC/tinyexpr.c" "$SRC/tinyexpr.h" "$BUILD_DIR/"

# Parse-only harness (write once; user can edit if they want a different
# entry point, e.g. te_interp for an FP-aware experiment).
HARNESS="$BUILD_DIR/harness.c"
if [ ! -f "$HARNESS" ]; then
    cat > "$HARNESS" <<'EOF'
/* Symbolic-execution harness for tinyexpr. We call te_compile (parse only),
 * not te_interp, because te_interp evaluates floating-point expressions and
 * KLEE can't reason symbolically over FP. te_compile exercises the entire
 * parser (tokenizer, precedence, error recovery) without doing any FP. */
#include "tinyexpr.h"

int main(int argc, char **argv) {
    if (argc < 2) return 1;
    int err = 0;
    te_expr *e = te_compile(argv[1], 0, 0, &err);
    if (e) te_free(e);
    return err;
}
EOF
fi

RESULTS="$REPO/results"
mkdir -p "$RESULTS"
TS=$(date +%Y%m%d-%H%M%S)
LOG="$RESULTS/tinyexpr-$TS.log"

log() { printf '[%s] %s\n' "$(date -Is)" "$*" | tee -a "$LOG"; }

log "tinyexpr benchmark: ${MINUTES} min, --sym-args 0 1 ${MAX_ARG_CHARS}"
log "log: $LOG"

# Build: gcov-instrumented native binary + linked LLVM bitcode for KLEE.
log "build: gcov + bitcode"
docker run --rm -v "$WORK:/work" "$IMAGE" bash -lc "
    set -e
    cd /work/tinyexpr
    # gcov build (native, line-count instrumented). Use --coverage on both
    # compile and link so clang's driver pulls in its own profile runtime.
    # The .o filename must NOT have a .gcov.o suffix because clang names the
    # emitted .gcno after the object file (e.g. -o foo.gcov.o -> foo.gcov.gcno),
    # and the coverage tool below expects foo.gcno.
    clang --coverage -O0 -g -c tinyexpr.c -o tinyexpr.o
    clang --coverage -O0 -g -c harness.c  -o harness.o
    clang --coverage tinyexpr.o harness.o -lm -o tinyexpr.gcov
    # bitcode build (for KLEE)
    clang -O0 -g -emit-llvm -c tinyexpr.c -o tinyexpr.bc
    clang -O0 -g -emit-llvm -c harness.c  -o harness.bc
    llvm-link tinyexpr.bc harness.bc -o tinyexpr.linked.bc
" >> "$LOG" 2>&1
log "build: done"

# KLEE flags: identical to the paper's coreutils flags (run-klee.sh) minus
# --sym-files / --sym-stdin (tinyexpr only reads argv).
KLEE_FLAGS=(
    --simplify-sym-indices --write-cvcs --write-cov --output-module
    --max-memory=1000 --disable-inlining --optimize
    --use-forked-solver --use-cex-cache
    --libc=uclibc --posix-runtime --external-calls=all
    --only-output-states-covering-new
    --max-sym-array-size=4096
    --max-solver-time=30s
    --max-time="${MINUTES}min"
    --watchdog --max-memory-inhibit=false
    --max-static-fork-pct=1 --max-static-solve-pct=1 --max-static-cpfork-pct=1
    --switch-type=internal
    --search=random-path --search=nurs:covnew
    --use-batching-search --batch-instructions=10000
    --output-dir=/work/klee-out/tinyexpr
)

OUTDIR="$WORK/klee-out/tinyexpr"
rm -rf "$OUTDIR"
mkdir -p "$WORK/klee-out"

log "klee: running for ${MINUTES} min"
docker run --rm --ulimit stack=-1:-1 -v "$WORK:/work" "$IMAGE" bash -lc "
    cd /work/tinyexpr
    klee ${KLEE_FLAGS[*]} ./tinyexpr.linked.bc --sym-args 0 1 ${MAX_ARG_CHARS}
" >> "$LOG" 2>&1
log "klee: done"

NTESTS=$(ls "$OUTDIR"/test*.ktest 2>/dev/null | wc -l)
log "ktests generated: $NTESTS"

log "replay + coverage"
# Use llvm-cov gcov, not the system gcov: clang's .gcno format isn't
# compatible with gcc's gcov (the system gcov segfaults on it).
docker run --rm -v "$WORK:/work" "$IMAGE" bash -lc "
    set -e
    cd /work/tinyexpr
    rm -f *.gcda *.gcov
    for t in /work/klee-out/tinyexpr/test*.ktest; do
        [ -f \"\$t\" ] || continue
        KLEE_REPLAY_TIMEOUT=3 klee-replay ./tinyexpr.gcov \"\$t\" 2>/dev/null || true
    done
    llvm-cov gcov -b tinyexpr.c
" >> "$LOG" 2>&1

# Stash the gcov-annotated source for the report and extract the headline numbers.
cp "$BUILD_DIR/tinyexpr.c.gcov" "$RESULTS/tinyexpr.c.gcov" 2>/dev/null || true
SUMMARY=$(awk -F: '
    /^Lines executed/    {gsub(/ /,"",$2); lines=$2}
    /^Branches executed/ {gsub(/ /,"",$2); branches=$2}
    END {printf "lines=%s  branches=%s", lines, branches}
' <(grep -A2 "File 'tinyexpr.c'" "$LOG" | tail -10))

{
    echo "=== tinyexpr coverage ==="
    echo "  budget:   ${MINUTES} min, --sym-args 0 1 ${MAX_ARG_CHARS}"
    echo "  ktests:   $NTESTS"
    echo "  $SUMMARY"
} | tee -a "$LOG" "$RESULTS/tinyexpr-coverage.txt"

log "done"
