# Handoff — klee-runner

You (the next Claude Code session) are picking this up mid-project. Read this
first. Then read `README.md` for the user-facing view, and
`references/cadar08.pdf` + `references/assignment.txt` for context.

## The assignment in one sentence

CSE 231 class project: pick a paper from the OS/systems community, reproduce
an experiment, write a 2–3 page report on how your results differ and what
that shows. The user picked **KLEE (Cadar et al., OSDI 2008)**.

## What we are reproducing

Table 2 / Figure 5 of the paper: KLEE's per-tool line coverage on **GNU
Coreutils**. The paper reports 84.5% aggregate / 94.7% median / 90.9% mean
coverage across 89 tools, with 16 tools at 100% and 56 at ≥90%, after ~60 min
of KLEE per tool. We are not trying to match the exact numbers — we are
trying to go through the reproduction motions, report the deltas, and reflect
on reproducibility per the assignment rubric.

## What is already done (as of this handoff)

1. **Docker-based toolchain chosen.** The user agreed not to pull KLEE as a
   submodule — building it from source is a ~30-minute rabbit hole (specific
   LLVM 13, STP, Z3, klee-uclibc). We use the official `klee/klee:3.1` image,
   pinned by digest `sha256:05e56e17d88ed02f2872ec2ec78e7c4282d0328dc203d0a5f05cc1d458688d8f`.
2. **Setup pipeline is scripted and tested.** `./scripts/setup.sh` downloads
   coreutils 6.11, applies two patches, and builds both a gcov variant and an
   LLVM-bitcode variant inside the container. It ends with a smoke-test KLEE
   run on `echo`. It is idempotent.
3. **A working build tree already exists at `./build/`** (i.e.
   `/home/ethan/GitHub/klee-runner/build/`) on this machine. The scripts
   default to that same `WORK` path, so they will pick it up without
   re-building. If you're on a fresh machine, just run `./scripts/setup.sh`.
4. **`run-klee.sh` and `measure-coverage.sh` exist** and mirror the paper's
   command line. Neither has been run end-to-end beyond the smoke test.

## What is *not* done yet

- Running KLEE on a non-trivial subset of tools (15–30 would be reasonable).
- Measuring coverage for each of those tools via gcov replay.
- Aggregating the numbers and comparing to the paper's.
- Writing the 2–3 page report (`report.md` or similar — user hasn't requested
  one yet, don't create it proactively).

## Two non-obvious things to know

1. **Run the container as the klee user (uid 1000), not as root.** `wllvm` is
   installed under `/home/klee/.local/` and breaks when Python is launched as
   root because it can't find its site-packages. All scripts already do this.
2. **Coreutils 6.11 does not build on modern glibc out of the box.** Two
   patches are required:
   - Upstream `coreutils-6.11-on-glibc-2.28.diff` — fixes
     `lib/freadahead.c` and `lib/fseterr.c`, which dereference `FILE`
     internals that glibc 2.28 made private.
   - Local `patches/sort-wnohang.patch` — on modern glibc, if `<stdlib.h>` is
     included before `<sys/wait.h>` *and* `__USE_XOPEN2K8` ends up defined
     (which is the case via `_GNU_SOURCE` in 6.11-era gnulib), neither header
     ends up defining `WNOHANG` / `WIFEXITED` / `WEXITSTATUS`. We add
     fallback defs in `src/sort.c`.

## Suggested next action

Ask the user what subset of tools they want to run, and for how long per
tool. Then loop over the subset running `run-klee.sh` followed by
`measure-coverage.sh`, collecting numbers into a CSV / table. Don't start a
60-minute-per-tool batch without explicit confirmation — that's 15+ hours for
a meaningful subset.

## Files worth re-reading before you start

- `README.md` — user-facing. If your plan diverges from what it describes,
  update the README so the two don't drift.
- `scripts/setup.sh` — the patches and build flags, inline and commented.
- `references/cadar08.pdf` §5.1–5.2 — the exact experimental setup being
  reproduced. The KLEE flag set in `run-klee.sh` comes from §5.2.
- `references/assignment.txt` — the grading rubric (step 3 "Reproduce" and
  step 4 "Report").

## Things you should NOT do without asking

- Move the `build/` tree to `/mnt/c/...` or any other NTFS-via-9P path. The
  user considered this earlier and backed off — bind-mount I/O from NTFS is
  10–30x slower for many-small-file builds. Keep it on ext4.
- Add KLEE as a git submodule. Explicitly rejected above.
- Rebuild the Docker image from source, or switch away from 3.1 without cause.
- Start long KLEE batches on your own. Ask.
