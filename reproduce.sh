#!/usr/bin/env bash
# reproduce.sh <model> --endpoint URL [--key KEY]
#
#   reproduce.sh some-model --endpoint https://your-openai-compatible-api --key YOUR_KEY
#
# Runs all 1,403 olmOCR-bench pages through the model's native doc2json recipe
# against ANY OpenAI-compatible endpoint, converts the replies to markdown
# (linearize.py), and scores them with AllenAI's official scorer. No GPU needed
# on this machine. About 20 minutes on a ~20 Mbps uplink.
#
# <model> must match a name advertised by <endpoint>/v1/models.
set -euo pipefail
MODEL="${1:?usage: reproduce.sh <model> --endpoint URL [--key KEY]}"; shift
ENDPOINT="${DEFAULT_ENDPOINT:-}"
KEY="${TACKLE_API_KEY:-}"
while [ $# -gt 0 ]; do case "$1" in
  --endpoint) ENDPOINT="${2:?--endpoint needs a URL}"; shift 2;;
  --key) KEY="${2:?--key needs a value}"; shift 2;;
  *) echo "unknown arg: $1"; exit 1;;
esac; done
[ -n "$ENDPOINT" ] || { echo "usage: reproduce.sh <model> --endpoint URL [--key KEY]"; exit 1; }
ENDPOINT="${ENDPOINT%/}"
HERE="$(cd "$(dirname "$0")" && pwd)"
NAME=$(basename "$MODEL" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '_' | sed 's/_*$//')
AUTH_ARGS=()
[ -n "$KEY" ] && AUTH_ARGS=(-H "Authorization: Bearer $KEY")

# 0) preflight, cheapest checks first so nothing fails 20 minutes in:
#    a) deps installed at all (catches a forgotten venv activate)
python3 -c 'import playwright, pypdfium2, requests, olmocr' 2>/dev/null \
  || { echo "!! Python deps missing. Activate the venv and: pip install -r requirements.txt"; exit 1; }

#    b) endpoint reachable and the key accepted (before any big download)
API_MODEL="$MODEL"
if ! MODELS_JSON=$(curl -sf -m 10 ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} "$ENDPOINT/v1/models" 2>/dev/null); then
  CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 10 ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} "$ENDPOINT/v1/models" || true)
  case "$CODE" in
    401|403) echo "!! $ENDPOINT rejected the request (HTTP $CODE)."
             echo "   Check your key (--key or TACKLE_API_KEY). Keys expire 7 days after issue.";;
    *)       echo "!! cannot reach $ENDPOINT/v1/models";;
  esac
  exit 1
fi
echo "$MODELS_JSON" | grep -q "\"$API_MODEL\"" || {
  echo "!! $ENDPOINT does not serve '$API_MODEL'. It advertises:"
  echo "$MODELS_JSON" | grep -o '"id":"[^"]*"' | grep -v modelperm | sed 's/^/     /'
  echo "   Serve the checkpoint with --served-model-name $API_MODEL, or pass the name it reports."
  exit 1; }

#    c) the scorer's math tests need a launchable headless chromium
python3 -m playwright install chromium >/dev/null 2>&1 || true
python3 - <<'PY' || { echo "!! chromium cannot launch: missing OS libraries."; \
  echo "   Fix: sudo python3 -m playwright install-deps chromium   (then rerun)"; exit 1; }
from playwright.sync_api import sync_playwright
with sync_playwright() as p:
    p.chromium.launch(headless=True).close()
PY

# 1) benchmark data (1,403 single-page PDFs + unit tests), from AllenAI
if [ -e "$HERE/bench_data" ] && [ ! -L "$HERE/bench_data" ]; then
  echo "!! $HERE/bench_data exists but is not the expected symlink. Move it aside and rerun"; exit 1
fi
# classic download path (see get_dataset.sh for the rate-limit math); no HF account needed
export HF_HUB_DISABLE_XET=1
DOWNLOAD_ATTEMPTS=5   # the download resumes where it left off, so retries are cheap
RETRY_WAIT_SECONDS=75
if [ ! -d "$HERE/bench_data/pdfs" ]; then
  echo ">> downloading olmOCR-bench data (~450 MB, one time)"
  # huggingface_hub >= 1.0 ships `hf`; older versions ship `huggingface-cli`
  HF_CLI=$(command -v hf || command -v huggingface-cli || true)
  [ -n "$HF_CLI" ] || { echo "!! no hf/huggingface-cli on PATH. pip install -r requirements.txt first"; exit 1; }
  ok=""
  for attempt in $(seq 1 "$DOWNLOAD_ATTEMPTS"); do
    # pinned to the dataset revision our published numbers were measured against
    if "$HF_CLI" download allenai/olmOCR-bench --repo-type dataset \
      --revision 54a96a6fb6a2bd3b297e59869491db4d3625b711 \
      --local-dir "$HERE/olmOCR-bench"; then ok=1; break; fi
    echo ">> download interrupted; resuming in ${RETRY_WAIT_SECONDS}s (attempt $attempt of $DOWNLOAD_ATTEMPTS)"
    sleep "$RETRY_WAIT_SECONDS"
  done
  [ -n "$ok" ] || { echo "!! download did not finish after $DOWNLOAD_ATTEMPTS attempts. Rerun this script; it resumes where it left off"; exit 1; }
  ln -sfn "$HERE/olmOCR-bench/bench_data" "$HERE/bench_data"
fi

# 2) run all pages (native prompt, 2400px renders, temp 0) -> markdown tree.
# CONCURRENCY = the one global in-flight cap; 32 matches the per-key limit
# on the public endpoint, which is sized to the serving pool.
python3 "$HERE/protocol/run_pages.py" \
  --endpoint "$ENDPOINT/v1/chat/completions" --model "$API_MODEL" \
  --pdfs "$HERE/bench_data/pdfs" --out "$HERE/bench_data/$NAME" \
  --concurrency "${CONCURRENCY:-32}" ${KEY:+--key "$KEY"}

# 3) completeness gate: a partial tree is never scored. The official scorer
# reports a hard failure on ANY missing page, so a transient network blip
# would otherwise read as a failed reproduction. Reruns resume: completed
# pages are skipped, only the gaps retry.
EXPECTED=$(find -L "$HERE/bench_data/pdfs" -name '*.pdf' | wc -l)
GOT=$(find -L "$HERE/bench_data/$NAME" -name '*_repeat1.md' 2>/dev/null | wc -l)
if [ "$GOT" -lt "$EXPECTED" ]; then
  echo "!! $((EXPECTED-GOT)) of $EXPECTED pages missing. NOT scoring a partial run."
  echo "   Re-run this exact command to retry just the missing pages."
  exit 1
fi

# 4) official scorer (AllenAI's code). It scores every candidate md-tree found
#    inside --dir; ours is the only one in a fresh download. Its math tests
#    render LaTeX in headless chromium; install is idempotent (~120MB once).
python3 -m playwright install chromium \
  || { echo "!! chromium install failed. On minimal distros run: python3 -m playwright install-deps chromium"; exit 1; }
python3 -m olmocr.bench.benchmark --dir "$HERE/bench_data"
