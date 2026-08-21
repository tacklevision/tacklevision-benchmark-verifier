#!/usr/bin/env python3
"""Build a self-contained HTML gallery: benchmark pages next to what the
model wrote for each. Pages render from the user's own verified local PDFs
(pypdfium2, no network), so what they see is what was tested.

Sampling is stratified: at least one page from every category, old scans
first (the most striking demonstration), remaining slots weighted toward the
visually interesting categories. Model output is shown exactly as scored
(raw text, no transformation): guaranteed-faithful display beats sometimes-
broken pretty rendering.

Usage: make_gallery.py <bench_data> <outputs_dir> <out.html> [n_samples]
"""
import base64
import html
import io
import os
import random
import sys
from collections import defaultdict

SHOWCASE = ["old_scans", "old_scans_math", "table_tests", "multi_column"]


def collect_pairs(bd, out):
    by_cat = defaultdict(list)
    pdf_root = os.path.join(bd, "pdfs")
    for cat in sorted(os.listdir(pdf_root)):
        catdir = os.path.join(pdf_root, cat)
        if not os.path.isdir(catdir):
            continue
        for fn in sorted(os.listdir(catdir)):
            if not fn.endswith(".pdf"):
                continue
            md = os.path.join(out, cat, fn[:-4] + "_pg1_repeat1.md")
            if os.path.exists(md):
                by_cat[cat].append((cat, os.path.join(catdir, fn), md))
    return by_cat


def stratified_sample(by_cat, n):
    picks = []
    for cat, items in by_cat.items():
        picks.append(random.choice(items))
    extras_pool = [it for cat in SHOWCASE for it in by_cat.get(cat, [])]
    everything = [it for items in by_cat.values() for it in items]
    chosen = {p[2] for p in picks}
    while len(picks) < n:
        pool = extras_pool if len(picks) < n * 3 // 4 and extras_pool else everything
        cand = random.choice(pool)
        if cand[2] in chosen:
            if len(chosen) >= len(everything):
                break
            continue
        picks.append(cand)
        chosen.add(cand[2])
    # old scans lead; the rest shuffled for variety
    lead = [p for p in picks if p[0] == "old_scans"]
    rest = [p for p in picks if p[0] != "old_scans"]
    random.shuffle(rest)
    return (lead + rest)[:n]


def render_pdf_jpeg(path, scale=1.6, quality=82):
    import pypdfium2 as pdfium
    doc = pdfium.PdfDocument(path)
    try:
        bitmap = doc[0].render(scale=scale)
        img = bitmap.to_pil().convert("RGB")
        buf = io.BytesIO()
        img.save(buf, format="JPEG", quality=quality)
        return base64.b64encode(buf.getvalue()).decode()
    finally:
        doc.close()


CSS = """
:root{--ink:#101623;--mut:#5a6b82;--line:#e3e9f2;--bg:#f6f8fb;--card:#fff;--acc:#0f62fe}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);
font:15px/1.55 -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif}
.wrap{max-width:1280px;margin:0 auto;padding:36px 28px}
h1{font-size:26px;margin:0 0 6px}
.sub{color:var(--mut);max-width:860px;margin:0 0 30px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;
margin:0 0 26px;overflow:hidden}
.head{display:flex;justify-content:space-between;gap:12px;align-items:center;
padding:12px 18px;border-bottom:1px solid var(--line)}
.badge{font-size:12px;font-weight:600;color:var(--acc);background:#eaf1ff;
border-radius:20px;padding:3px 12px;white-space:nowrap}
.fn{font-family:ui-monospace,Menlo,monospace;font-size:12px;color:var(--mut);
overflow-wrap:anywhere}
.cols{display:grid;grid-template-columns:1fr 1fr}
@media(max-width:900px){.cols{grid-template-columns:1fr}}
.col{padding:16px;min-width:0}
.col+.col{border-left:1px solid var(--line)}
.lbl{font-size:11px;font-weight:700;letter-spacing:.08em;text-transform:uppercase;
color:var(--mut);margin:0 0 10px}
img.page{width:100%;height:auto;border:1px solid var(--line);border-radius:6px}
pre.raw{margin:0;white-space:pre-wrap;overflow-wrap:anywhere;font:12.5px/1.6 ui-monospace,
Menlo,monospace;color:#1c2a3f;max-height:720px;overflow-y:auto}
"""

def main():
    bd, out, dest = sys.argv[1], sys.argv[2], sys.argv[3]
    n = int(sys.argv[4]) if len(sys.argv) > 4 else 12
    by_cat = collect_pairs(bd, out)
    if not by_cat:
        print("no document/output pairs found", file=sys.stderr)
        sys.exit(1)
    sample = stratified_sample(by_cat, n)

    cards = []
    for cat, pdf, md in sample:
        try:
            jpg = render_pdf_jpeg(pdf)
        except Exception as e:
            print(f"   (skipping {os.path.basename(pdf)}: {e})", file=sys.stderr)
            continue
        text = open(md, errors="replace").read().strip() or "(model wrote nothing for this page)"
        cards.append(f"""
<div class="card">
 <div class="head"><span class="badge">{html.escape(cat)}</span>
  <span class="fn">{html.escape(os.path.basename(pdf))}</span></div>
 <div class="cols">
  <div class="col"><p class="lbl">The benchmark page (your verified local copy)</p>
   <img class="page" alt="benchmark page" src="data:image/jpeg;base64,{jpg}"></div>
  <div class="col"><p class="lbl">What the model read from it (exactly as scored)</p>
   <pre class="raw">{html.escape(text)}</pre>
  </div>
 </div>
</div>""")

    doc = f"""<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>What is being tested · TackleVision verification</title>
<style>{CSS}</style></head><body><div class="wrap">
<h1>What is being tested</h1>
<p class="sub">A sample of {len(cards)} of the 1,403 pages in AllenAI's
olmOCR benchmark (every category represented), rendered from the verified copy
on your machine, with the model's reading of each page beside it, shown
exactly as the scorer judged it, byte for byte. Every other page can be
inspected the same way in
<code>bench_data/pdfs/</code>; rerun scoring for a fresh sample.</p>
{''.join(cards)}
</div></body></html>"""
    with open(dest, "w") as f:
        f.write(doc)
    print(dest)


if __name__ == "__main__":
    main()
