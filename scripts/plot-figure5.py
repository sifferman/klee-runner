#!/usr/bin/env python3
"""plot-figure5.py — reproduce Figure 5 of Cadar et al. 2008.

Reads results/coverage.csv (produced by benchmark-coverage.sh) and writes
an SVG in the style of the paper's Figure 5: per-tool line coverage sorted
ascending, two-tone bars showing how much extra coverage syscall-failure
injection buys you. Black bar = Base+Fail (taller); gray bar in front =
Base only — the visible black above the gray is the fail-injection bonus.

Six horizontal reference lines: paper's three Table 2 stats (dashed) and
our three matching stats (solid).

Matplotlib infers format from the --out extension, so pass --out
results/figure5.png if you want a raster image instead.

Usage:
    ./scripts/plot-figure5.py
    ./scripts/plot-figure5.py --csv results/coverage.csv --out results/figure5.svg
"""

import argparse
import csv
import pathlib
import statistics
import sys

import matplotlib.pyplot as plt

# Emit <text> elements instead of rasterizing glyphs to <path>
plt.rcParams["svg.fonttype"] = "none"
plt.rcParams["font.family"] = "serif"
plt.rcParams["font.serif"] = [
    "Times New Roman", "Times", "Liberation Serif", "DejaVu Serif", "serif",
]
plt.rcParams["mathtext.fontset"] = "stix"

# Paper's Table 2 numbers for Coreutils × KLEE, from §5.2.1 on p.9.
# These are Base+Fail unioned values — the standard KLEE run plus a second
# pass with --max-fail 1 (syscall failure injection). benchmark-coverage.sh
# runs both passes so our numbers are apples-to-apples with these.
PAPER_OVERALL = 84.5  # Table 2 "Overall cov."     (weighted total)
PAPER_MEDIAN  = 94.7  # Table 2 "Med cov/App"      (per-tool median)
PAPER_MEAN    = 90.9  # Table 2 "Ave cov/App"      (per-tool arithmetic mean)

# Palette: overall=red, median=blue, mean=green. Paper dashed, ours solid.
COLOR_OVERALL = "tab:red"
COLOR_MEDIAN  = "tab:blue"
COLOR_MEAN    = "tab:green"


def load(csv_path: pathlib.Path):
    """Read the wide CSV. Falls back to the old single-column format if the
    new columns aren't present (so old coverage.csv files still plot, just
    without the two-tone bars).

    Mathematical invariant: Base+Fail combined coverage is the union of
    Base alone and Fail-only ktests, so combined >= base always. A
    measurement violating this (libgcov's .gcda file isn't crash-safe — a
    fail-injection replay that aborts mid-write can corrupt the shared
    counters and produce combined < base) is clamped to base, with a
    warning emitted to stderr."""
    rows = []
    anomalies = []
    with csv_path.open() as f:
        reader = csv.DictReader(f)
        cols = reader.fieldnames or []
        wide = "lines_pct_combined" in cols
        for r in reader:
            if wide:
                if not r["lines_pct_combined"]:
                    continue
                base = float(r["lines_pct_base"]) if r["lines_pct_base"] else 0.0
                comb = float(r["lines_pct_combined"])
                if comb < base:
                    anomalies.append((r["tool"], base, comb))
                    comb = base
                total = int(r["lines_total"])
            else:
                if not r["lines_pct"]:
                    continue
                base = comb = float(r["lines_pct"])
                total = int(r["lines_total"])
            rows.append({"tool": r["tool"], "base": base, "combined": comb, "total": total})
    if anomalies:
        print(f"warning: clamped combined<base for {len(anomalies)} tool(s) "
              f"(libgcov .gcda corruption from crashing fail-injection replays):",
              file=sys.stderr)
        for t, b, c in anomalies:
            print(f"  {t}: raw combined={c:.2f}% < base={b:.2f}%, plotting {b:.2f}%",
                  file=sys.stderr)
    rows.sort(key=lambda r: r["combined"])
    return rows, wide


def summarize(rows, key):
    cov = [r[key] for r in rows]
    total_covered = sum(r[key] * r["total"] / 100 for r in rows)
    total_lines = sum(r["total"] for r in rows)
    return {
        "n": len(rows),
        "weighted": total_covered / total_lines * 100 if total_lines else 0,
        "mean": statistics.mean(cov),
        "median": statistics.median(cov),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", default="results/coverage.csv")
    ap.add_argument("--out", default="results/figure5.svg")
    args = ap.parse_args()

    csv_path = pathlib.Path(args.csv)
    out_path = pathlib.Path(args.out)
    if not csv_path.exists():
        sys.exit(f"error: no CSV at {csv_path} — run ./scripts/benchmark-coverage.sh first")

    rows, wide = load(csv_path)
    if not rows:
        sys.exit(f"error: {csv_path} has no parseable rows")
    summary = summarize(rows, "combined")
    tools    = [r["tool"]     for r in rows]
    base     = [r["base"]     for r in rows]
    combined = [r["combined"] for r in rows]

    fig, ax = plt.subplots(figsize=(14, 5))
    xs = range(len(rows))
    # Draw the taller (combined) bars first in black, then the shorter (base)
    # bars in light gray on top — the visible black above each gray bar is
    # the coverage gained from --max-fail 1 syscall failure injection.
    ax.bar(xs, combined, width=0.9, color="black",     edgecolor="black",
           label="Base + Fail (with syscall failure injection)")
    if wide:
        ax.bar(xs, base, width=0.9, color="lightgray", edgecolor="black",
               linewidth=0.3, label="Base (standard run)")
    ax.set_ylim(0, 100)
    ax.set_xlim(-0.5, len(rows) - 0.5)
    ax.set_ylabel("Coverage (ELOC %)")
    ax.set_xticks(list(xs))
    ax.set_xticklabels(tools, rotation=90, fontsize=9)
    ax.tick_params(axis="x", pad=1)

    ax.axhline(PAPER_OVERALL, color=COLOR_OVERALL, linestyle="--", linewidth=1.2,
               label=f"Paper overall: {PAPER_OVERALL}%")
    ax.axhline(PAPER_MEDIAN, color=COLOR_MEDIAN, linestyle="--", linewidth=1.2,
               label=f"Paper median: {PAPER_MEDIAN}%")
    ax.axhline(PAPER_MEAN, color=COLOR_MEAN, linestyle="--", linewidth=1.2,
               label=f"Paper mean: {PAPER_MEAN}%")
    ax.axhline(summary["weighted"], color=COLOR_OVERALL, linestyle="-", linewidth=1.5,
               label=f"Our overall: {summary['weighted']:.1f}%")
    ax.axhline(summary["median"], color=COLOR_MEDIAN, linestyle="-", linewidth=1.5,
               label=f"Our median: {summary['median']:.1f}%")
    ax.axhline(summary["mean"], color=COLOR_MEAN, linestyle="-", linewidth=1.5,
               label=f"Our mean: {summary['mean']:.1f}%")

    ax.legend(loc="lower right", fontsize=9, framealpha=0.9)
    ax.set_title(
        f"KLEE line coverage on {summary['n']} coreutils tools "
        f"(60 min/tool per run, Base + Base+Fail unioned)"
    )

    fig.tight_layout()
    fig.savefig(out_path, dpi=150)
    print(f"wrote {out_path}")
    print(f"  n={summary['n']}  combined-overall={summary['weighted']:.2f}%  "
          f"combined-mean={summary['mean']:.2f}%  combined-median={summary['median']:.2f}%")
    if wide:
        b = summarize(rows, "base")
        print(f"            base-overall={b['weighted']:.2f}%  "
              f"base-mean={b['mean']:.2f}%  base-median={b['median']:.2f}%")


if __name__ == "__main__":
    main()
