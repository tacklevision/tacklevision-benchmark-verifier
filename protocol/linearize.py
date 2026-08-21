import json
import re

DROP_CATS = {"header", "footer", "page_footnote"}

def strip_wrappers(s: str) -> str:
    s = re.sub(r"<think>.*?</think>", "", s, flags=re.DOTALL).strip()
    m = re.search(r"```(?:json|markdown)?\s*(.*?)```", s, flags=re.DOTALL)
    if m:
        s = m.group(1).strip()
    return s


def _find_elements(obj):
    """Return the list of layout-element dicts from whatever shape the JSON is."""
    if isinstance(obj, list):
        return [e for e in obj if isinstance(e, dict)]
    if isinstance(obj, dict):
        # common keys first
        for k in ("layout", "elements", "layouts", "result", "data", "items"):
            v = obj.get(k)
            if isinstance(v, list):
                return [e for e in v if isinstance(e, dict)]
        # else: first list-of-dicts value
        for v in obj.values():
            if isinstance(v, list) and v and isinstance(v[0], dict):
                return [e for e in v if isinstance(e, dict)]
    return []


def linearize(raw: str) -> str:
    """doc2json -> markdown. Drop furniture, keep reading order (model already sorts)."""
    s = strip_wrappers(raw)
    try:
        obj = json.loads(s)
    except Exception:
        # not parseable as JSON -> treat as already-markdown (doc2md fallback)
        return raw.strip()
    parts = []
    for e in _find_elements(obj):
        cat = str(e.get("category", e.get("type", ""))).strip().lower()
        if cat in DROP_CATS or cat == "figure":
            continue
        txt = e.get("text", e.get("text_content", e.get("content", "")))
        if isinstance(txt, list):
            txt = "\n".join(str(t) for t in txt)
        elif txt is not None and not isinstance(txt, str):
            txt = str(txt)  # never crash on odd model output; worst case is odd text
        txt = (txt or "").strip()
        if txt:
            parts.append(txt)
    return "\n\n".join(parts).strip()

