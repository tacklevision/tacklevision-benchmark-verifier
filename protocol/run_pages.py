#!/usr/bin/env python3
"""Run every olmOCR-bench page through the model's native doc2json recipe.

Renders each single-page PDF at 2400px longest side (the model's native
resolution), sends it with the verbatim prompt from prompt.txt at temperature 0,
converts the JSON reply to markdown via linearize.py, and writes the tree the
official scorer expects: <out>/<category>/<stem>_pg1_repeat1.md

Auth: pass --key (or set ENDPOINT_API_KEY) and it is sent as a Bearer token to
the endpoint you named. The key only gates access to that endpoint; it never
affects the outputs.

Reruns resume: pages with an existing output are skipped, so an interrupted
run only redoes the gaps. A .protocol stamp in the output dir refuses to mix
outputs across protocol changes (prompt/decode/model updates).

Exit codes: 0 all pages written; 1 some pages failed (rerun retries just
those) or the endpoint rejected the key; 3 the endpoint looks down (a run of
connection-class failures with no success at all, or none recently), so
nothing was attempted past that point and a rerun resumes.
"""
import argparse, base64, concurrent.futures as cf, hashlib, io, json, os, sys, threading, time
import pypdfium2 as pdfium
import requests

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from linearize import linearize  # the audited converter; read it

PROMPT = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "prompt.txt"),
              encoding="utf-8").read()


def _num(s):
    return int(s) if s.strip().isdigit() else float(s)


# operational knobs, all from the environment (protocol constants live in the
# payload below and in protocol_stamp; nothing here touches them)
CONNECT_TIMEOUT = _num(os.environ.get("CONNECT_TIMEOUT", "10"))     # TCP connect, seconds
READ_TIMEOUT = _num(os.environ.get("READ_TIMEOUT", "900"))          # waiting for the reply, seconds
RETRIES = int(os.environ.get("RETRIES", "3"))                       # attempts per page
BREAKER_CONSECUTIVE = int(os.environ.get("BREAKER_CONSECUTIVE", "20"))  # see Breaker
BREAKER_QUIET_SECONDS = _num(os.environ.get("BREAKER_QUIET_SECONDS", "300"))  # see Breaker
EXIT_ENDPOINT_UNREACHABLE = 3


class AuthError(RuntimeError):
    """401/403 from the endpoint: retrying cannot help, fail the run fast."""


class EndpointDown(RuntimeError):
    """The breaker tripped: the endpoint, not a page, is the problem."""


class Breaker:
    """Counts connection-class failures (refused, reset, timeout, 5xx) across all
    threads and trips when the endpoint, not a page, is the problem:
      * BREAKER_CONSECUTIVE failures in a row while no page has ever succeeded
        (the endpoint was never up), or
      * BREAKER_CONSECUTIVE failures in a row with no success in the last
        BREAKER_QUIET_SECONDS (it was up and went away mid-run).
    Grinding through 1,403 pages times RETRIES against a dead endpoint helps
    nobody; a rerun resumes. A success resets the streak, so per-page failures
    on a live endpoint stay per-page."""

    def __init__(self, limit, quiet_seconds):
        self.limit = limit
        self.quiet_seconds = quiet_seconds
        self.consecutive = 0
        self.successes = 0
        self.last_success_at = None
        self.last_error = ""
        self.tripped = threading.Event()
        self._lock = threading.Lock()

    def success(self):
        with self._lock:
            self.consecutive = 0
            self.successes += 1
            self.last_success_at = time.monotonic()

    def failure(self, err):
        with self._lock:
            self.consecutive += 1
            self.last_error = str(err)[:200]
            if self.consecutive < self.limit:
                return
            if self.successes == 0 or time.monotonic() - self.last_success_at >= self.quiet_seconds:
                self.tripped.set()


def is_connection_class(exc):
    if isinstance(exc, (requests.ConnectionError, requests.Timeout)):
        return True
    return (isinstance(exc, requests.HTTPError) and exc.response is not None
            and exc.response.status_code >= 500)


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

def one(args, cat, fn, breaker):
    stem = os.path.splitext(fn)[0]
    op = os.path.join(args.out, cat, f"{stem}_pg1_repeat1.md")
    # existence alone means done: writes are atomic, and a legitimately empty
    # page (rare but real) must not regenerate on every rerun
    if os.path.exists(op):
        return "skip"
    if breaker.tripped.is_set():
        return "aborted"
    os.makedirs(os.path.dirname(op), exist_ok=True)
    # render ONCE per page, outside the retry loop: a retry re-sends the same
    # image, it never re-renders (rendering is CPU work that a dead endpoint
    # would otherwise multiply by RETRIES across every page)
    try:
        image = render(os.path.join(args.pdfs, cat, fn))
    except Exception as e:
        print(f"FAIL {cat}/{fn}: could not render: {e}", file=sys.stderr)
        return "err"
    # the exact decode config our published numbers were measured with:
    # greedy, thinking disabled (vLLM chat-template kwarg), 16k budget
    payload = {
        "model": args.model, "temperature": 0.0, "top_p": 1.0, "max_tokens": 16384,
        "chat_template_kwargs": {"enable_thinking": False},
        "messages": [{"role": "user", "content": [
            {"type": "image_url", "image_url": {"url": image}},
            {"type": "text", "text": PROMPT}]}],
    }
    headers = {"Authorization": "Bearer " + args.key} if args.key else {}
    for attempt in range(RETRIES):
        if breaker.tripped.is_set():
            return "aborted"
        try:
            r = requests.post(args.endpoint, json=payload, headers=headers,
                              timeout=(CONNECT_TIMEOUT, READ_TIMEOUT))
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
            breaker.success()
            return "ok"
        except AuthError:
            raise
        except Exception as e:
            if is_connection_class(e):
                breaker.failure(e)
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
    ap.add_argument("--key", default=os.environ.get("ENDPOINT_API_KEY", ""),
                    help="API key for the endpoint (default: ENDPOINT_API_KEY env)")
    args = ap.parse_args()
    protocol_stamp(args)
    jobs = [(cat, fn) for cat in sorted(os.listdir(args.pdfs))
            if os.path.isdir(os.path.join(args.pdfs, cat))
            for fn in sorted(os.listdir(os.path.join(args.pdfs, cat))) if fn.endswith(".pdf")]
    print(f"{len(jobs)} pages")
    tally = {"ok": 0, "skip": 0, "err": 0, "aborted": 0}
    done = 0
    breaker = Breaker(BREAKER_CONSECUTIVE, BREAKER_QUIET_SECONDS)
    with cf.ThreadPoolExecutor(args.concurrency) as ex:
        futs = [ex.submit(one, args, cat, fn, breaker) for cat, fn in jobs]
        try:
            for f in cf.as_completed(futs):
                tally[f.result()] += 1
                done += 1
                if breaker.tripped.is_set():
                    raise EndpointDown(breaker.last_error)
                if done % 100 == 0:
                    print(f"{done}/{len(jobs)}")
        except AuthError as e:
            for p in futs:
                p.cancel()
            sys.exit(f"!! {e}. Pass --key with a key for THAT endpoint (or set ENDPOINT_API_KEY). "
                     f"A TackleVision verification key is not an endpoint key: for a verified run "
                     f"use verify.sh.")
        except EndpointDown as e:
            for p in futs:
                p.cancel()
            since = (f"in the last {BREAKER_QUIET_SECONDS} s" if breaker.successes else "at all")
            print(f"!! the endpoint looks unreachable: {BREAKER_CONSECUTIVE} connection failures in a row "
                  f"and no page has succeeded {since} ({e}).\n"
                  f"   Nothing is lost. Re-run the same command once it is back; completed pages are skipped.",
                  file=sys.stderr)
            sys.exit(EXIT_ENDPOINT_UNREACHABLE)
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
