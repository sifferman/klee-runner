# klee-runner

Reproducing Table 2 / Figure 5 of **Cadar, Dunbar & Engler, *KLEE: Unassisted and
Automatic Generation of High-Coverage Tests for Complex Systems Programs*
(OSDI 2008)** — specifically, the per-tool line coverage that KLEE achieves on
GNU Coreutils 6.10 (the paper's target; we use 6.11, the version the official
KLEE tutorial uses).

## What the paper claims

| Measure (w/o library)         | Paper's Coreutils result |
| ----------------------------- | ------------------------ |
| Overall (aggregate) coverage  | 84.5%                    |
| Median per-tool coverage      | 94.7%                    |
| Average per-tool coverage     | 90.9%                    |
| Tools at 100%                 | 16 of 89                 |
| Tools at ≥90%                 | 56 of 89                 |

With 60 minutes of KLEE per tool on a 2008-era machine.

## Prerequisites

- **Docker** (tested with 29.x). Linux host or WSL2.
- **~15 GB free disk** (10.5 GB for the KLEE image, ~200 MB for the build tree,
  more if you run KLEE on many tools).
- `bash`, `wget`, `patch` on the host (the scripts shell out to the container
  for everything heavy).

We use the official `klee/klee:3.1` Docker image (KLEE 3.1 + LLVM 13 + clang +
STP + klee-uclibc + POSIX runtime), pinned by sha256 digest in the scripts.
Building KLEE from source is not required and not recommended for this project.

## Quickstart

```bash
# One-shot: pull image, fetch coreutils-6.11, patch, build both versions.
# Takes ~10 minutes the first time; idempotent afterwards.
./scripts/setup.sh

# Run KLEE on one tool for N minutes (defaults to 60).
./scripts/run-klee.sh echo 1
./scripts/run-klee.sh pr   60

# Replay the generated tests on the gcov-instrumented binary and print
# line coverage for that tool.
./scripts/measure-coverage.sh pr
```

Workspace location (where coreutils and KLEE outputs live) defaults to
`./build` (relative to the repo root). Override with
`WORK=/some/path ./scripts/...`.

## What each script does

**`scripts/setup.sh`** (see the script for the exact commands — it is meant to
be readable):
1. `docker pull` the pinned KLEE image.
2. Download `coreutils-6.11.tar.gz` from gnu.org.
3. Apply the upstream `coreutils-6.11-on-glibc-2.28.diff` (fixes gnulib's
   `freadahead.c` / `fseterr.c` for modern glibc).
4. Apply `patches/sort-wnohang.patch` (local — provides fallback `WNOHANG` /
   `WIFEXITED` / `WEXITSTATUS` in `src/sort.c`; modern glibc hides these from
   `<sys/wait.h>` when `__USE_XOPEN2K8` is set *after* `<stdlib.h>` was
   already included, which is the case with 6.11-era gnulib wrappers).
5. Build `obj-gcov/` — native binaries with `-fprofile-arcs -ftest-coverage`,
   used later to measure coverage by replaying KLEE's tests.
6. Build `obj-llvm/` with `wllvm` — produces executables whose object files
   embed LLVM bitcode; `extract-bc` then writes `*.bc` alongside each binary.
7. Smoke-test KLEE on `echo`.

**`scripts/run-klee.sh <tool> [minutes]`** runs KLEE with the exact flag set
from §5.2 of the paper (mirrored in the KLEE repo's
`examples/coreutils/run_klee.sh`):

```
--simplify-sym-indices --write-cvcs --write-cov --output-module
--max-memory=1000 --disable-inlining --optimize
--use-forked-solver --use-cex-cache
--libc=uclibc --posix-runtime --external-calls=all
--only-output-states-covering-new
--max-sym-array-size=4096 --max-solver-time=30s --max-time=<N>min
--watchdog --max-memory-inhibit=false
--max-static-fork-pct=1 --max-static-solve-pct=1 --max-static-cpfork-pct=1
--switch-type=internal
--search=random-path --search=nurs:covnew
--use-batching-search --batch-instructions=10000
<tool>.bc --sym-args 0 1 10 --sym-args 0 2 2
          --sym-files 1 8 --sym-stdin 8 --sym-stdout
```

**`scripts/measure-coverage.sh <tool>`** invokes `klee-replay` on every
`.ktest` file in the tool's output directory against the gcov-instrumented
binary, then runs `gcov` and prints the line-coverage percentage for that
tool's `.c` file.

## Running on many tools

The paper reports over 89 tools × 60 min = 89 CPU-hours. For a class project
you probably want a subset. A reasonable starting selection (mix of simple and
hard tools, picked to match Figure 9 of the paper):

```bash
for t in echo yes true false pwd nohup tee comm expr od seq tr paste pr; do
    ./scripts/run-klee.sh "$t" 60
    ./scripts/measure-coverage.sh "$t" | tee -a results.log
done
```

## Layout

```
README.md               # this file
handoff.md              # context dump for a fresh Claude Code session
references/             # paper + assignment (git-ignored contents)
├── cadar08.pdf
└── assignment.txt
patches/
└── sort-wnohang.patch  # local coreutils-6.11 patch
scripts/
├── setup.sh            # pull image, build coreutils (both variants)
├── run-klee.sh         # KLEE on one tool (paper's flags)
└── measure-coverage.sh # klee-replay + gcov on one tool
build/                  # default $WORK — git-ignored
├── coreutils-6.11/     #   obj-gcov/ and obj-llvm/ builds
└── klee-out/<tool>/    #   per-tool KLEE output
```

## Known deviations from the paper

- **Coreutils version.** Paper: 6.10. We use 6.11 (one dot release later; the
  version the official KLEE tutorial uses; very similar LOC).
- **Host environment.** Paper: 2008-era hardware, ~89 CPU-hours total. You
  won't reproduce the "sort beat developers' tests over 15 years" claim
  meaningfully in a class project; pick a subset.
- **KLEE version.** Paper: the KLEE-of-2008 (pre-release). We use KLEE 3.1 /
  LLVM 13. The core algorithms are the same; the solver and the POSIX runtime
  are both more capable, so coverage should be at least as good per tool,
  though the per-tool numbers will not match exactly.
- **glibc patch.** Needed to build coreutils 6.10/6.11 on modern glibc — see
  `scripts/setup.sh` step 4.

## References

- Cadar, Dunbar, Engler. *KLEE: Unassisted and Automatic Generation of
  High-Coverage Tests for Complex Systems Programs.* OSDI 2008.
  [`references/cadar08.pdf`](references/cadar08.pdf)
- KLEE project, "Testing Coreutils" tutorial.
  <https://klee-se.org/tutorials/testing-coreutils/>
- Upstream coreutils build-older-versions patches.
  <https://github.com/coreutils/coreutils/tree/master/scripts/build-older-versions>
