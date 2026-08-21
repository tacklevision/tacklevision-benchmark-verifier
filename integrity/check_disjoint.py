#!/usr/bin/env python3
"""check_disjoint.py: train/eval contamination gate.

Asserts that the PDF stems of the RL training set are DISJOINT from the
olmOCR-bench eval PDFs, and exits non-zero on any overlap. We ran this before
any training: 1,947 training stems vs 1,403 eval stems, overlap 0.

The training set itself is private (it ships with the weights on request), so
an outsider cannot rerun this directly; it is included so the gate we used is
inspectable, and so anyone who receives the weights can rerun it verbatim.

Paths come from env (TRAIN_DIR, OLMBENCH_DIR) or flags.
"""
import argparse
import glob
import os
import sys


def pdf_stems(root):
    """All bare pdf stems under a directory tree (category-agnostic, so
    cross-category duplicates are caught too)."""
    out = set()
    for p in glob.glob(os.path.join(root, "**", "*.pdf"), recursive=True):
        out.add(os.path.splitext(os.path.basename(p))[0])
    return out


def main():
    e = os.environ.get
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--train-dir", default=e("TRAIN_DIR"),
                    help="root of the training-set PDFs")
    ap.add_argument("--bench-dir", default=e("OLMBENCH_DIR",
                    os.path.join(here, "..", "olmOCR-bench", "bench_data")),
                    help="olmOCR-bench bench_data dir (reproduce.sh downloads it here)")
    args = ap.parse_args()

    if not args.train_dir:
        sys.exit("!! pass --train-dir (or set TRAIN_DIR): the training set to check")
    ev_pdfs = os.path.join(args.bench_dir, "pdfs")
    for d in (args.train_dir, ev_pdfs):
        if not os.path.isdir(d):
            sys.exit(f"!! missing dir: {d}")

    train_stems, ev_stems = pdf_stems(args.train_dir), pdf_stems(ev_pdfs)
    overlap = sorted(train_stems & ev_stems)

    print("=" * 70)
    print(f"train pdf stems: {len(train_stems)}   eval pdf stems: {len(ev_stems)}")
    print(f"STEM OVERLAP: {len(overlap)}")
    for s in overlap[:50]:
        print(f"   {s}")
    print("=" * 70)

    if overlap:
        print(f"!! CONTAMINATION: {len(overlap)} training pages overlap the eval set. "
              f"Drop them before training, or any benchmark gain is partly memorization.",
              file=sys.stderr)
        sys.exit(2)
    print(">> DISJOINT: no train/eval pdf-stem overlap.")
    sys.exit(0)


if __name__ == "__main__":
    main()
