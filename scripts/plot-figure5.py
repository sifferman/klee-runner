#!/usr/bin/env python3
"""plot-figure5.py — reproduce Figure 5 of Cadar et al. 2008.

Reads results/coverage.csv (produced by benchmark-coverage.sh) and writes
an SVG in the same style as the paper's Figure 5: per-tool line coverage
sorted ascending, y-axis 0-100%. Overlays six reference lines — the paper's
three Table 2 stats (dashed) and our three matching stats (solid).

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
    rows = []
    with csv_path.open() as f:
        for r in csv.DictReader(f):
            if not r["lines_pct"]:
                continue
            rows.append((r["tool"], float(r["lines_pct"]), int(r["lines_total"])))
    rows.sort(key=lambda r: r[1])
    return rows


def summarize(rows):
    cov = [r[1] for r in rows]
    total_covered = sum(r[1] * r[2] / 100 for r in rows)
    total_lines = sum(r[2] for r in rows)
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

    rows = load(csv_path)
    if not rows:
        sys.exit(f"error: {csv_path} has no parseable rows")
    summary = summarize(rows)
    tools = [r[0] for r in rows]
    cov = [r[1] for r in rows]

    fig, ax = plt.subplots(figsize=(14, 5))
    ax.bar(range(len(cov)), cov, width=0.9, color="black", edgecolor="black")
    ax.set_ylim(0, 100)
    ax.set_xlim(-0.5, len(cov) - 0.5)
    ax.set_ylabel("Coverage (ELOC %)")
    ax.set_xticks(range(len(tools)))
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
        f"(60 min/tool, 10-way parallel)"
    )

    fig.tight_layout()
    fig.savefig(out_path, dpi=150)
    print(f"wrote {out_path}")
    print(f"  n={summary['n']}  agg={summary['weighted']:.2f}%  "
          f"mean={summary['mean']:.2f}%  median={summary['median']:.2f}%")


if __name__ == "__main__":
    main()
