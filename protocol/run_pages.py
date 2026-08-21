#!/usr/bin/env python3
"""Run every olmOCR-bench page through the model's native doc2json recipe.

Renders each single-page PDF at 2400px longest side (the model's native
resolution), sends it with the verbatim prompt from prompt.txt at temperature 0,
converts the JSON reply to markdown via linearize.py, and writes the tree the
official scorer expects: <out>/<category>/<stem>_pg1_repeat1.md

Auth: pass --key (or set TACKLE_API_KEY) and it is sent as a Bearer token.
The key only gates access to the endpoint; it never affects the outputs.

Reruns resume: pages with an existing output are skipped, so an interrupted
run only redoes the gaps. A .protocol stamp in the output dir refuses to mix
outputs across protocol changes (prompt/decode/model updates).
"""
import argparse, base64, concurrent.futures as cf, hashlib, io, json, os, sys, threading, time
import pypdfium2 as pdfium
import requests

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from linearize import linearize  # the audited converter; read it

PROMPT = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "prompt.txt"),
              encoding="utf-8").read()
# operational knobs (protocol constants live in the payload below)
TIMEOUT = int(os.environ.get("REQUEST_TIMEOUT", "900"))
RETRIES = int(os.environ.get("RETRIES", "3"))

class AuthError(RuntimeError):
    """401/403 from the endpoint: retrying cannot help, fail the run fast."""

# pdfium is not thread-safe: the document's full lifecycle (open, render,
# close) is serialized. Rendering is tens of ms per page, negligible next to
# the LLM call, so this costs no wall-clock; the requests stay concurrent.
_RENDER_LOCK = threading.Lock()

def render(path, longest=2400):
    with _RENDER_LOCK:
        doc = pdfium.PdfDocument(path)
        try:
            page = doc[0]
            scale = longest / max(page.get_size())
            pil = page.render(scale=scale).to_pil()
        finally:
            doc.close()
    buf = io.BytesIO(); pil.save(buf, format="PNG")
    return "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode()

def one(args, cat, fn):
    stem = os.path.splitext(fn)[0]
    op = os.path.join(args.out, cat, f"{stem}_pg1_repeat1.md")
    # existence alone means done: writes are atomic, and a legitimately empty
    # page (rare but real) must not regenerate on every rerun
    if os.path.exists(op):
        return "skip"
    os.makedirs(os.path.dirname(op), exist_ok=True)
    for attempt in range(RETRIES):
        try:
            # the exact decode config our published numbers were measured with:
            # greedy, thinking disabled (vLLM chat-template kwarg), 16k budget
            payload = {
                "model": args.model, "temperature": 0.0, "top_p": 1.0, "max_tokens": 16384,
                "chat_template_kwargs": {"enable_thinking": False},
                "messages": [{"role": "user", "content": [
                    {"type": "image_url", "image_url": {"url": render(os.path.join(args.pdfs, cat, fn))}},
                    {"type": "text", "text": PROMPT}]}],
            }
            headers = {"Authorization": "Bearer " + args.key} if args.key else {}
            r = requests.post(args.endpoint, json=payload, headers=headers, timeout=TIMEOUT)
            if r.status_code in (401, 403):
                raise AuthError(f"endpoint rejected the request (HTTP {r.status_code})")
            r.raise_for_status()
            choice = r.json()["choices"][0]
            if choice.get("finish_reason") == "length":
                # Deterministic behavior on a rare degraded page: the model
                # rambles to the 16k cap. The published protocol counts such a
                # page as its honest zero (the scorer fails its tests), it does
                # NOT fail the run. Noted here and in the receipt for transparency.
                print(f"NOTE {cat}/{fn}: hit max_tokens; writing output as-is "
                      f"(page scores its honest zero)", file=sys.stderr)
            md = linearize(choice["message"]["content"])
            tmp = op + ".tmp"                 # convert + write atomically so a
            with open(tmp, "w", encoding="utf-8") as f:   # killed run can't leave a
                f.write(md)                   # truncated file that resume trusts
            os.replace(tmp, op)
            return "ok"
        except AuthError:
            raise
        except Exception as e:
            if attempt == RETRIES - 1:
                print(f"FAIL {cat}/{fn}: {e}", file=sys.stderr)
                return "err"
            time.sleep(2 ** attempt)

def protocol_stamp(args):
    """Refuse to resume over outputs produced by a different protocol."""
    fp = hashlib.sha256(json.dumps({
        "prompt": PROMPT, "model": args.model, "temperature": 0.0, "top_p": 1.0,
        "max_tokens": 16384, "enable_thinking": False, "render_px": 2400,
    }, sort_keys=True).encode()).hexdigest()[:16]
    os.makedirs(args.out, exist_ok=True)
    stamp = os.path.join(args.out, ".protocol")
    if os.path.exists(stamp):
        old = open(stamp, encoding="utf-8").read().strip()
        if old != fp:
            sys.exit(f"!! {args.out} holds outputs from an older protocol ({old} != {fp}).\n"
                     f"   Delete that directory and rerun: mixing generations would corrupt the score.")
    else:
        with open(stamp, "w", encoding="utf-8") as f:
            f.write(fp)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--endpoint", required=True)
    ap.add_argument("--model", default="repro")
    ap.add_argument("--pdfs", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--concurrency", type=int, default=32)
    ap.add_argument("--key", default=os.environ.get("TACKLE_API_KEY", ""),
                    help="API key for the endpoint (default: TACKLE_API_KEY env)")
    args = ap.parse_args()
    protocol_stamp(args)
    jobs = [(cat, fn) for cat in sorted(os.listdir(args.pdfs))
            if os.path.isdir(os.path.join(args.pdfs, cat))
            for fn in sorted(os.listdir(os.path.join(args.pdfs, cat))) if fn.endswith(".pdf")]
    print(f"{len(jobs)} pages")
    tally = {"ok": 0, "skip": 0, "err": 0}
    done = 0
    with cf.ThreadPoolExecutor(args.concurrency) as ex:
        futs = [ex.submit(one, args, cat, fn) for cat, fn in jobs]
        try:
            for f in cf.as_completed(futs):
                tally[f.result()] += 1
                done += 1
                if done % 100 == 0:
                    print(f"{done}/{len(jobs)}")
        except AuthError as e:
            for p in futs:
                p.cancel()
            sys.exit(f"!! {e}. Pass --key (or set TACKLE_API_KEY). "
                     f"Request a key at the verification page if you do not have one.")
        except BaseException:
            # Ctrl-C or an unexpected error: without this, the executor would
            # quietly run every queued page before the traceback appears.
            for p in futs:
                p.cancel()
            print("!! aborted. Re-run the same command to resume; completed pages are skipped.",
                  file=sys.stderr)
            raise
    print(f"done: {tally['ok']} generated, {tally['skip']} resumed, {tally['err']} FAILED")
    if tally["err"]:
        print(f"!! {tally['err']} pages failed. Re-run the same command to retry just those "
              f"(completed pages are skipped). Scoring a partial tree reports a hard failure.",
              file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
