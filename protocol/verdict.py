#!/usr/bin/env python3
"""Render the final verdict from AllenAI's scorer output.

Reads the raw scorer log (kept on disk, unmodified, for anyone who wants the
blob), pulls the last candidate's overall score and per-category rows, and
prints a readable verdict against the published claim. The scorer itself is
never touched: this is presentation over its saved output.
"""
import argparse
import json
import os
import re
import sys

CLAIM_LOW, CLAIM_HIGH = 86.1, 86.6   # published claim on the benchmark page
NOISE = 1.0                          # "differences under a point are noise"

BOLD, DIM, RESET = "\033[1m", "\033[2m", "\033[0m"
GREEN, YELLOW, CYAN = "\033[32m", "\033[33m", "\033[36m"

# chunky 3x5 block font for the headline number
FONT = {
    "0": ["###", "# #", "# #", "# #", "###"],
    "1": [" ##", "  #", "  #", "  #", "  #"],
    "2": ["###", "  #", "###", "#  ", "###"],
    "3": ["###", "  #", "###", "  #", "###"],
    "4": ["# #", "# #", "###", "  #", "  #"],
    "5": ["###", "#  ", "###", "  #", "###"],
    "6": ["###", "#  ", "###", "# #", "###"],
    "7": ["###", "  #", "  #", "  #", "  #"],
    "8": ["###", "# #", "###", "# #", "###"],
    "9": ["###", "# #", "###", "  #", "###"],
    ".": ["   ", "   ", "   ", "   ", " # "],
    "%": ["# #", "  #", " # ", "#  ", "# #"],
}

FRIENDLY = {
    "arxiv_math.jsonl": "Scientific papers (arXiv + math)",
    "headers_footers.jsonl": "Headers and footers",
    "long_tiny_text.jsonl": "Long documents, tiny text",
    "multi_column.jsonl": "Multi-column layouts",
    "old_scans.jsonl": "Old scans",
    "old_scans_math.jsonl": "Old scans, handwritten math",
    "table_tests.jsonl": "Tables",
    "base.jsonl": "Baseline output checks",
}


def big(text):
    rows = [""] * 5
    for ch in text:
        pat = FONT.get(ch)
        if not pat:
            continue
        for i in range(5):
            rows[i] += "".join("██" if c == "#" else "  " for c in pat[i]) + "  "
    return [r.rstrip() for r in rows]


def parse(log_path):
    txt = open(log_path, errors="replace").read()
    # last candidate summary block wins (a log may hold several)
    heads = list(re.finditer(
        r"^(\S+)\s*:\s*Average Score:\s*([\d.]+)%\s*(?:±\s*([\d.]+)%)?", txt, re.M))
    if not heads:
        return None
    m = heads[-1]
    cats = []
    for cm in re.finditer(r"^\s+([a-z0-9_]+\.jsonl)\s*:\s*([\d.]+)%\s*\((\d+)/(\d+)",
                          txt[m.end():], re.M):
        cats.append((cm.group(1), float(cm.group(2)), int(cm.group(3)), int(cm.group(4))))
    return {"name": m.group(1), "score": float(m.group(2)),
            "pm": float(m.group(3)) if m.group(3) else None, "cats": cats}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("scorer_log")
    ap.add_argument("--receipt", help="receipt_<run>.json for provenance footer")
    args = ap.parse_args()

    r = parse(args.scorer_log)
    if not r:
        print(f"!! could not find a score in {args.scorer_log}; the raw scorer "
              f"output is preserved there for inspection", file=sys.stderr)
        sys.exit(1)

    score, pm = r["score"], r["pm"]
    in_band = (CLAIM_LOW - NOISE) <= score <= (CLAIM_HIGH + NOISE)
    color = GREEN if in_band else YELLOW
    W = 76
    ansi = re.compile(r"\033\[[0-9;]*m")

    def line(s=""):
        pad = (W - 2) - len(ansi.sub("", s))
        print(f"{color}│{RESET}{s}{' ' * max(0, pad)}{color}│{RESET}")

    print()
    print(color + "┌" + "─" * (W - 2) + "┐" + RESET)
    line(f"  {BOLD}TACKLEVISION  ·  INDEPENDENT BENCHMARK VERIFICATION{RESET}")
    line()
    headline = f"{score:.1f}%"
    for row in big(headline):
        line("      " + BOLD + color + row + RESET)
    line()
    pm_txt = f" ± {pm:.1f}" if pm is not None else ""
    line(f"      your run, scored on your machine{pm_txt}")
    line(f"      published claim: {CLAIM_LOW} to {CLAIM_HIGH} (under 1 point apart is noise)")
    line()
    if in_band:
        line(f"      {BOLD}{GREEN}RESULT: MATCHES THE PUBLISHED CLAIM{RESET}")
    else:
        line(f"      {BOLD}{YELLOW}RESULT: OUTSIDE THE PUBLISHED RANGE{RESET}")
        line("      please reply to your approval email with this screen. We want")
        line("      to know.")
    line()
    if r["cats"]:
        line(f"  {DIM}what was tested{RESET}                                {DIM}score      tests{RESET}")
        for cat, pct, ok, tot in r["cats"]:
            name = FRIENDLY.get(cat, cat)
            line(f"  {name:<44s}{pct:5.1f}%  {ok:>5d}/{tot:<5d}")
        line()
    print(color + "└" + "─" * (W - 2) + "┘" + RESET)

    print(f"{DIM}   scored by AllenAI's official olmOCR-bench tool, unmodified, on this")
    print("   machine, over outputs you can read page by page.")
    if args.receipt and os.path.exists(args.receipt):
        try:
            rc = json.load(open(args.receipt))
            print(f"   run {rc.get('run_id', '?')} · model {rc.get('model', '?')} · "
                  f"dataset manifest {str(rc.get('dataset_manifest_sha256', ''))[:16]}...")
        except Exception:
            pass
    print(f"   raw scorer output preserved at: {args.scorer_log}{RESET}")
    print()


if __name__ == "__main__":
    main()
