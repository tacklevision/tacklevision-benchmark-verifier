#!/usr/bin/env bash
# score.sh <outputs_RUNID.tar.gz>: score run outputs with AllenAI's official
# tool, locally, on your machine. Run from the verifier repo dir after setup
# (venv + dataset download): the scorer needs bench_data + your outputs.
set -euo pipefail
TAR="${1:?usage: score.sh outputs_<run>.tar.gz}"
HERE="$(cd "$(dirname "$0")" && pwd)"
BD="$HERE/bench_data"
GALLERY_SAMPLES=12
BOLD=$'\033[1m'; GREEN=$'\033[32m'; DIM=$'\033[2m'; RESET=$'\033[0m'
[ -d "$BD/pdfs" ] || { echo "!! bench_data not found next to score.sh. Run get_dataset.sh first, from the verifier repo."; exit 1; }

RUN_TAG="$(basename "$TAR" .tar.gz)"; RUN_TAG="${RUN_TAG#outputs_}"
SCORER_LOG="$HERE/scorer_${RUN_TAG}.log"

echo "${BOLD}>> proving the dataset on this machine is the official one${RESET}"
python3 "$HERE/integrity/manifest.py" verify "$BD" \
  --expected-hash "fded36af2edbe541ee822ffd623d192560b7b14aefdb828b62c2961e94005d51" \
  || { echo "!! your local dataset does not match the pinned official revision"; exit 2; }

# the scorer renders math in headless chromium; make sure it exists
# (idempotent: instant no-op when already installed)
python3 -m playwright install chromium >/dev/null 2>&1 || true
python3 - <<'PY' || { echo "!! chromium cannot launch. Try: python3 -m playwright install chromium"; \
  echo "   (on minimal Linux: sudo python3 -m playwright install-deps chromium)"; exit 1; }
from playwright.sync_api import sync_playwright
with sync_playwright() as p:
    p.chromium.launch(headless=True).close()
PY

STAGE="$(mktemp -d)/bench_data"
mkdir -p "$STAGE"
for f in "$BD"/*.jsonl; do ln -s "$f" "$STAGE/$(basename "$f")"; done
ln -s "$BD/pdfs" "$STAGE/pdfs"
mkdir -p "$STAGE/tacklevision"
tar -xzf "$TAR" --strip-components=1 -C "$STAGE/tacklevision"

# something better than staring at a progress bar: a browsable gallery of the
# actual benchmark pages (their verified local copies) next to what the model
# wrote for each one
GALLERY="$HERE/gallery_${RUN_TAG}.html"
if python3 "$HERE/protocol/make_gallery.py" "$BD" "$STAGE/tacklevision" "$GALLERY" "$GALLERY_SAMPLES" >/dev/null 2>&1; then
  echo
  echo "${BOLD}>> While the scorer runs, see what is being tested with your own eyes.${RESET}"
  echo "   Open this in your browser (it never opens itself):"
  echo "   ${GREEN}$GALLERY${RESET}"
  echo "   $GALLERY_SAMPLES benchmark pages, each next to what the model read from it."
fi

echo
echo "${BOLD}>> Handing off to AllenAI's official scorer (unmodified; that is the point).${RESET}"
echo "   TIMING: the FIRST scoring run on a machine takes 20-40 minutes; it renders"
echo "   thousands of math equations in a browser once and caches them. The ETA on"
echo "   its progress bar is misleading early on. Repeat runs take a few minutes."
echo
echo "   The published claim you are about to check: ${BOLD}86.1 to 86.6${RESET}"
echo

# stdout (summary + per-test results) is preserved verbatim for inspection;
# the scorer's live progress stays on screen
python3 -m olmocr.bench.benchmark --dir "$STAGE" | tee "$SCORER_LOG"

# the same numbers, readable
python3 "$HERE/protocol/verdict.py" "$SCORER_LOG" --receipt "$HERE/receipt_${RUN_TAG}.json" || true

if [ -f "$GALLERY" ]; then
  echo "   See what was tested, page by page (opens in a browser):"
  echo "   ${GREEN}$GALLERY${RESET}"
  echo
fi

# every verification counts: record the score on the independent-run ledger
# (only for real gateway runs: needs your key and this run's receipt)
SCORE=$(tr '\r' '\n' < "$SCORER_LOG" | grep "average of per-JSONL scores" | tail -1 \
        | grep -oE "[0-9]+\.[0-9]+" | head -1 || true)
if [ -n "${TV_API_KEY:-}" ] && [ -n "$SCORE" ] && [ -f "$HERE/receipt_${RUN_TAG}.json" ]; then
  API="${TV_API_URL:-https://mk7y315169.execute-api.us-east-1.amazonaws.com/v1}"
  if curl -sf -X POST -H "x-api-key: $TV_API_KEY" -H "Content-Type: application/json" \
       -d "{\"score\": $SCORE}" "$API/runs/${RUN_TAG}/result" >/dev/null 2>&1; then
    echo "   Your score ($SCORE) is recorded on the independent-run ledger. Thank you."
  else
    echo "   ${DIM}(could not reach the ledger to record $SCORE; your receipt still proves the run)${RESET}"
  fi
  echo
fi

echo "${BOLD}   That was the public benchmark. Your documents are the real test.${RESET}"
echo "   See TackleVision on them: ${GREEN}https://tackle.ai/demo/${RESET}"
echo
