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
import time

CLAIM_LOW, CLAIM_HIGH = 86.1, 86.6   # published claim on the benchmark page
NOISE = 1.0                          # "differences under a point are noise"
# one per-category row of the scorer's "Results by JSONL file" block. The
# scorer prints 7 categories as <name>.jsonl and the 8th as bare "baseline";
# all 8 are in its headline average, so all 8 must be in this table
CATEGORY_ROW_RE = r"^\s+([a-z0-9_]+(?:\.jsonl)?)\s*:\s*([\d.]+)%\s*\((\d+)/(\d+)"

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
    "baseline": "Baseline (page has text; in the average)",   # <= 44 chars: the table column
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


def fmt_dur(sec):
    sec = max(0, int(sec))
    m, s = divmod(sec, 60)
    return f"{m} min {s} s" if m else f"{s} s"


def parse(log_path):
    txt = open(log_path, errors="replace").read()
    # last candidate summary block wins (a log may hold several)
    heads = list(re.finditer(
        r"^(\S+)\s*:\s*Average Score:\s*([\d.]+)%\s*(?:±\s*([\d.]+)%)?", txt, re.M))
    if not heads:
        return None
    m = heads[-1]
    cats = []
    for cm in re.finditer(CATEGORY_ROW_RE, txt[m.end():], re.M):
        cats.append((cm.group(1), float(cm.group(2)), int(cm.group(3)), int(cm.group(4))))
    return {"name": m.group(1), "score": float(m.group(2)),
            "pm": float(m.group(3)) if m.group(3) else None, "cats": cats}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("scorer_log")
    ap.add_argument("--receipt", help="receipt_<run>.json for provenance footer")
    ap.add_argument("--started", type=int, help="epoch seconds the whole run began (verify.sh)")
    ap.add_argument("--scoring-started", type=int, help="epoch seconds scoring began (score.sh)")
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
        # the headline IS the plain average of these rows (the scorer's
        # "average of per-JSONL scores"); show it so the table visibly adds up
        avg = sum(c[1] for c in r["cats"]) / len(r["cats"])
        line(f"  {DIM}average of the {len(r['cats'])} rows above = {avg:.2f}%{RESET}")
        line()
    # how long it took, answered here because "how long did it take" is the one
    # question every tester gets asked and nobody could answer after walking away
    now = int(time.time())
    parts = []
    if args.started:
        parts.append(f"{fmt_dur(now - args.started)} in total")
    if args.scoring_started:
        parts.append(f"scoring {fmt_dur(now - args.scoring_started)}")
    if parts:
        line(f"  time: {parts[0]}" + (f" ({parts[1]})" if len(parts) == 2 else ""))
        line()
    # provenance, inside the frame: what scored it, which run, where the raw log is
    line(f"  {DIM}scored by AllenAI's official olmOCR-bench tool, unmodified, on this{RESET}")
    line(f"  {DIM}machine, over outputs you can read page by page.{RESET}")
    if args.receipt and os.path.exists(args.receipt):
        try:
            rc = json.load(open(args.receipt))
            line(f"  {DIM}run {str(rc.get('run_id', '?'))[:12]} · model {rc.get('model', '?')} · "
                 f"manifest {str(rc.get('dataset_manifest_sha256', ''))[:12]}...{RESET}")
        except Exception:
            pass
    line(f"  {DIM}raw scorer output kept in this folder: {os.path.basename(args.scorer_log)}{RESET}")
    print(color + "└" + "─" * (W - 2) + "┘" + RESET)
    print()


if __name__ == "__main__":
    main()
