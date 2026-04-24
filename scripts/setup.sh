#!/usr/bin/env bash
# setup.sh — one-shot setup: pull KLEE image, download + patch + build coreutils.
#
# Idempotent: each step checks if its output already exists and skips if so.
# Safe to re-run after a partial failure.
#
# Usage:
#   ./scripts/setup.sh                  # use default WORK=<repo>/build
#   WORK=/some/path ./scripts/setup.sh  # override workspace

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-$REPO/build}"
IMAGE="${KLEE_IMAGE:-klee/klee@sha256:05e56e17d88ed02f2872ec2ec78e7c4282d0328dc203d0a5f05cc1d458688d8f}"
COREUTILS_VERSION="6.11"

# -------- Functions for running commands inside the container --------
# Run as the klee user (uid 1000). wllvm is installed only for this user.
kdocker() {
    docker run --rm --ulimit stack=-1:-1 \
        -v "$WORK:/work" \
        -e LLVM_COMPILER=clang \
        "$IMAGE" bash -lc "$*"
}
# Run as root (needed only for chown)
kdocker_root() {
    docker run --rm --user 0 --ulimit stack=-1:-1 \
        -v "$WORK:/work" \
        "$IMAGE" bash -lc "$*"
}

say() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }

# -------- 1. Pull the KLEE image (pinned by digest) --------
say "Pulling KLEE image ($IMAGE)"
docker pull "$IMAGE"

# -------- 2. Prepare workspace --------
say "Preparing workspace at $WORK"
mkdir -p "$WORK"
# Fix ownership so the klee user (uid 1000) inside the container can write.
if [ "$(stat -c %u "$WORK")" != "1000" ]; then
    kdocker_root "chown -R 1000:1000 /work"
fi

# -------- 3. Download coreutils --------
TARBALL="coreutils-${COREUTILS_VERSION}.tar.gz"
if [ ! -f "$WORK/$TARBALL" ]; then
    say "Downloading $TARBALL"
    kdocker "cd /work && wget -q https://ftp.gnu.org/gnu/coreutils/$TARBALL"
fi
if [ ! -d "$WORK/coreutils-${COREUTILS_VERSION}" ]; then
    say "Extracting $TARBALL"
    kdocker "cd /work && tar xf $TARBALL"
fi

# -------- 4. Apply glibc-2.28 compatibility patch (gnulib fix) --------
PATCH_DIR="$WORK/coreutils-build-older"
GLIBC_PATCH="coreutils-${COREUTILS_VERSION}-on-glibc-2.28.diff"
if [ ! -f "$PATCH_DIR/$GLIBC_PATCH" ]; then
    say "Downloading upstream glibc-2.28 patch"
    kdocker "mkdir -p /work/coreutils-build-older && cd /work/coreutils-build-older && \
        wget -q https://raw.githubusercontent.com/coreutils/coreutils/master/scripts/build-older-versions/$GLIBC_PATCH"
fi
# Marker file so we only patch once.
STAMP="$WORK/coreutils-${COREUTILS_VERSION}/.patches-applied"
if [ ! -f "$STAMP" ]; then
    say "Applying glibc-2.28 gnulib patch"
    kdocker "cd /work/coreutils-${COREUTILS_VERSION} && \
        patch -p1 --forward < /work/coreutils-build-older/$GLIBC_PATCH"

    say "Applying local sort.c WNOHANG patch"
    # Copy patch into workdir so container can see it.
    cp "$REPO/patches/sort-wnohang.patch" "$WORK/"
    kdocker "cd /work/coreutils-${COREUTILS_VERSION} && \
        patch -p1 --forward < /work/sort-wnohang.patch"

    touch "$STAMP"
fi

# -------- 5. Build coreutils with gcov (native binaries, for coverage replay) --------
if [ ! -x "$WORK/coreutils-${COREUTILS_VERSION}/obj-gcov/src/echo" ]; then
    say "Building coreutils with gcov instrumentation"
    kdocker "set -e; cd /work/coreutils-${COREUTILS_VERSION} && \
        mkdir -p obj-gcov && cd obj-gcov && \
        ../configure --disable-nls \
            CFLAGS='-g -fprofile-arcs -ftest-coverage -U_FORTIFY_SOURCE' && \
        make -j\$(nproc)"
fi

# -------- 6. Build coreutils as LLVM bitcode (via wllvm) --------
if [ ! -f "$WORK/coreutils-${COREUTILS_VERSION}/obj-llvm/src/echo.bc" ]; then
    say "Building coreutils as LLVM bitcode (wllvm)"
    kdocker "set -e; cd /work/coreutils-${COREUTILS_VERSION} && \
        mkdir -p obj-llvm && cd obj-llvm && \
        CC=wllvm ../configure --disable-nls \
            CFLAGS='-g -O1 -Xclang -disable-llvm-passes -D__NO_STRING_INLINES -D_FORTIFY_SOURCE=0 -U__OPTIMIZE__' && \
        make -j\$(nproc)"

    say "Extracting bitcode from LLVM binaries"
    kdocker "cd /work/coreutils-${COREUTILS_VERSION}/obj-llvm/src && \
        find . -maxdepth 1 -executable -type f | xargs -I {} extract-bc {}"
fi

# -------- 7. Smoke test --------
say "Sanity check: running KLEE on echo (should finish in <60s)"
kdocker "cd /work/coreutils-${COREUTILS_VERSION}/obj-llvm/src && \
    timeout 90 klee --only-output-states-covering-new --optimize \
        --libc=uclibc --posix-runtime \
        --output-dir=/tmp/klee-smoke \
        ./echo.bc --sym-args 0 2 4 2>&1 | tail -3"

cat <<EOF

============================================================
 Setup complete.

   Workspace:           $WORK
   Native + gcov build: $WORK/coreutils-${COREUTILS_VERSION}/obj-gcov/src/
   LLVM bitcode:        $WORK/coreutils-${COREUTILS_VERSION}/obj-llvm/src/*.bc

 Next steps:
   ./scripts/run-klee.sh <tool> [minutes]       # run KLEE on one tool
   ./scripts/measure-coverage.sh <tool>         # replay + gcov coverage
============================================================
EOF
