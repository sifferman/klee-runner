#!/usr/bin/env bash
# run-klee.sh — run KLEE on a single coreutils tool using the OSDI'08 paper's
# command-line flags (see Cadar et al. 2008, §5.2).
#
# Usage:
#   ./scripts/run-klee.sh <tool> [minutes] [max-fail]
#
# Example:
#   ./scripts/run-klee.sh echo 1
#   ./scripts/run-klee.sh pr   60
#   ./scripts/run-klee.sh pr   60 1      # syscall-failure-injection pass
#
# Output:
#   $WORK/klee-out/<tool>/       — standard run (no failure injection)
#   $WORK/klee-out-fail/<tool>/  — failure-injection run (when max-fail is set)

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <tool> [minutes, default=60] [max-fail, default=none]" >&2
    exit 1
fi

TOOL="$1"
MINUTES="${2:-60}"
MAX_FAIL="${3:-}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-$REPO/build}"
IMAGE="${KLEE_IMAGE:-klee/klee@sha256:05e56e17d88ed02f2872ec2ec78e7c4282d0328dc203d0a5f05cc1d458688d8f}"
COREUTILS_DIR="coreutils-6.11"

BC="$WORK/$COREUTILS_DIR/obj-llvm/src/$TOOL.bc"
if [ ! -f "$BC" ]; then
    echo "error: bitcode not found at $BC — run ./scripts/setup.sh first" >&2
    exit 1
fi

# A --max-fail run goes to a sibling directory so the standard run's ktests
# aren't overwritten; measure-coverage.sh replays both into one gcov session
# to produce the Base+Fail unioned coverage the paper's Table 2 reports.
OUTDIR_NAME="klee-out"
FAIL_FLAGS=()
if [ -n "$MAX_FAIL" ]; then
    OUTDIR_NAME="klee-out-fail"
    FAIL_FLAGS=(--max-fail "$MAX_FAIL")
fi

OUTDIR_HOST="$WORK/$OUTDIR_NAME/$TOOL"
rm -rf "$OUTDIR_HOST"
mkdir -p "$WORK/$OUTDIR_NAME"

# The exact flags from the KLEE paper's Coreutils experiment (§5.2, p. 9).
# These are also the flags in klee's own repo/examples/coreutils.
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
    --output-dir=/work/$OUTDIR_NAME/$TOOL
)

# Paper's symbolic input: up to 3 args (1+2), each 2 chars, 2 files of 8 bytes, stdin 8 bytes.
# (See paper p. 9: "--sym-args 10 2 2 --sym-files 2 8"; we mirror the klee repo's refinement.)
# --max-fail is a posix-runtime option, so it goes in this argv block.
SYM_ARGS=(
    --sym-args 0 1 10
    --sym-args 0 2 2
    --sym-files 1 8
    --sym-stdin 8
    --sym-stdout
    "${FAIL_FLAGS[@]}"
)

MODE="standard"
[ -n "$MAX_FAIL" ] && MODE="--max-fail $MAX_FAIL"
echo "==> Running KLEE on $TOOL for $MINUTES minute(s) ($MODE)"
docker run --rm --ulimit stack=-1:-1 \
    -v "$WORK:/work" \
    "$IMAGE" bash -lc "cd /work/$COREUTILS_DIR/obj-llvm/src && \
        klee ${KLEE_FLAGS[*]} ./$TOOL.bc ${SYM_ARGS[*]}"

echo "==> Done. Output: $OUTDIR_HOST"
echo "==> Stats:"
docker run --rm --ulimit stack=-1:-1 -v "$WORK:/work" "$IMAGE" \
    bash -lc "klee-stats /work/$OUTDIR_NAME/$TOOL"
