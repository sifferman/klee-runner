#!/usr/bin/env bash
# measure-coverage.sh — replay KLEE tests on the gcov-instrumented binary and
# report line coverage for one tool.
#
# Usage:
#   ./scripts/measure-coverage.sh <tool>
#
# Requires:
#   - ./scripts/setup.sh has been run
#   - ./scripts/run-klee.sh <tool> has been run (so ktest files exist)

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <tool>" >&2
    exit 1
fi

TOOL="$1"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-$REPO/build}"
IMAGE="${KLEE_IMAGE:-klee/klee@sha256:05e56e17d88ed02f2872ec2ec78e7c4282d0328dc203d0a5f05cc1d458688d8f}"
COREUTILS_DIR="coreutils-6.11"

GCOV_BIN="$WORK/$COREUTILS_DIR/obj-gcov/src/$TOOL"

# Replay ktests from BOTH the standard run and the --max-fail run (if present)
# into a single gcov session — this gives Base+Fail unioned coverage, matching
# the paper's Table 2 methodology.
HAVE_ANY=0
for d in "$WORK/klee-out/$TOOL" "$WORK/klee-out-fail/$TOOL"; do
    [ -d "$d" ] && HAVE_ANY=1
done
if [ "$HAVE_ANY" -eq 0 ]; then
    echo "error: no KLEE output for $TOOL under $WORK/klee-out{,/fail}/ — run ./scripts/run-klee.sh $TOOL first" >&2
    exit 1
fi
if [ ! -x "$GCOV_BIN" ]; then
    echo "error: no gcov binary at $GCOV_BIN — run ./scripts/setup.sh first" >&2
    exit 1
fi

echo "==> Replaying KLEE tests on $TOOL (gcov build)"
# klee-replay re-executes the native binary with the concrete inputs stored in
# each .ktest file, producing .gcda coverage data files.
docker run --rm --ulimit stack=-1:-1 -v "$WORK:/work" "$IMAGE" bash -lc "
    set -e
    cd /work/$COREUTILS_DIR/obj-gcov/src
    rm -f *.gcda
    for dir in /work/klee-out/$TOOL /work/klee-out-fail/$TOOL; do
        [ -d \"\$dir\" ] || continue
        for t in \"\$dir\"/test*.ktest; do
            [ -f \"\$t\" ] || continue
            KLEE_REPLAY_TIMEOUT=3 klee-replay ./$TOOL \"\$t\" 2>/dev/null || true
        done
    done
    echo '==> Coverage report:'
    gcov -b $TOOL 2>&1 | grep -A2 \"File '../../src/$TOOL.c'\"
"
