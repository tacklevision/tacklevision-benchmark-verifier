#!/usr/bin/env bash
# score.sh <outputs_RUNID.tar.gz>: score run outputs with AllenAI's official
# tool, locally, on your machine. Run from the verifier repo dir after setup
# (venv + dataset download): the scorer needs bench_data + your outputs.
#
# Before scoring, the outputs are checked against the receipt that came with
# them: integrity/tree_hash.py recomputes output_tree_sha256 over every file
# in the tar and it must equal the receipt's value, or nothing is scored.
set -euo pipefail
TAR="${1:?usage: score.sh outputs_<run>.tar.gz}"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/client_common.sh"

# ---- constants -------------------------------------------------------------
PINNED_MANIFEST="fded36af2edbe541ee822ffd623d192560b7b14aefdb828b62c2961e94005d51"
GALLERY_SAMPLES=12
CLAIM_TEXT="86.1 to 86.6"          # the published claim being checked
BD="$HERE/bench_data"

[ -d "$BD/pdfs" ] || { echo "!! bench_data not found next to score.sh. Run get_dataset.sh first, from the verifier repo."; exit 1; }
[ -f "$TAR" ] || { echo "!! $TAR not found"; exit 1; }

RUN_TAG="$(basename "$TAR" .tar.gz)"; RUN_TAG="${RUN_TAG#outputs_}"
SCORER_LOG="$HERE/scorer_${RUN_TAG}.log"
TAR_DIR="$(cd "$(dirname "$TAR")" && pwd)"

echo "${BOLD}>> proving the dataset on this machine is the official one${RESET}"
python3 "$HERE/integrity/manifest.py" verify "$BD" --expected-hash "$PINNED_MANIFEST" \
  || { echo "!! your local dataset does not match the pinned official revision"; exit 2; }

# ---- unpack, then hold the outputs to their receipt ------------------------
STAGE="$(mktemp -d)/bench_data"
mkdir -p "$STAGE"
for f in "$BD"/*.jsonl; do ln -s "$f" "$STAGE/$(basename "$f")"; done
ln -s "$BD/pdfs" "$STAGE/pdfs"
mkdir -p "$STAGE/tacklevision"
tar -xzf "$TAR" --strip-components=1 -C "$STAGE/tacklevision"

# the receipt sits next to the outputs: receipt_<run>.json for gateway runs,
# receipt.json in published_run/
RECEIPT=""
for cand in "$HERE/receipt_${RUN_TAG}.json" "$TAR_DIR/receipt_${RUN_TAG}.json" "$TAR_DIR/receipt.json"; do
  if [ -f "$cand" ]; then RECEIPT="$cand"; break; fi
done
if [ -n "$RECEIPT" ]; then
  EXPECT=$(j output_tree_sha256 < "$RECEIPT")
  if [ -n "$EXPECT" ]; then
    echo "${BOLD}>> checking the outputs against their receipt (output_tree_sha256)${RESET}"
    python3 "$HERE/integrity/tree_hash.py" "$STAGE/tacklevision" --expect "$EXPECT" || {
      echo "!! the outputs in $(basename "$TAR") do not match the receipt's output_tree_sha256."
      echo "   This is not the tree we produced for that run (a damaged download, or edited files)."
      echo "   Not scoring it. Re-download with: bash fetch.sh <run id>"
      exit 2; }
    echo "   ${GREEN}matches the receipt${RESET}: output tree $EXPECT"
  else
    echo "   (receipt $(basename "$RECEIPT") carries no output_tree_sha256; skipping the tree-hash check)"
  fi
else
  echo "   (no receipt found next to $(basename "$TAR"); skipping the tree-hash check."
  echo "    gateway runs save receipt_<run id>.json beside the outputs)"
fi

# the scorer renders math in headless chromium; make sure it exists
# (idempotent: instant no-op when already installed)
python3 -m playwright install chromium >/dev/null 2>&1 || true
python3 - <<'PY' || { echo "!! chromium cannot launch. Try: python3 -m playwright install chromium"; \
  echo "   (on minimal Linux: sudo $(command -v python3) -m playwright install-deps chromium)"; exit 1; }
from playwright.sync_api import sync_playwright
with sync_playwright() as p:
    p.chromium.launch(headless=True).close()
PY

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
echo "   The published claim you are about to check: ${BOLD}$CLAIM_TEXT${RESET}"
echo

# stdout (summary + per-test results) is preserved verbatim for inspection;
# the scorer's live progress stays on screen
python3 -m olmocr.bench.benchmark --dir "$STAGE" | tee "$SCORER_LOG"

# the same numbers, readable
python3 "$HERE/protocol/verdict.py" "$SCORER_LOG" ${RECEIPT:+--receipt "$RECEIPT"} || true

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
  KEY="$TV_API_KEY"
  http_post "$API/runs/${RUN_TAG}/result" "{\"score\": $SCORE}"
  MSG=$(echo "$BODY" | j error)
  case "$HTTP" in
    200) echo "   Your score ($SCORE) is recorded on the independent-run ledger. Thank you.";;
    401|403)
      # a run is bound to the key that started it; a new key would not reach it
      echo "   ${DIM}this key can no longer reach run ${RUN_TAG} (HTTP $HTTP), so the score was not"
      echo "   recorded on the ledger. Your outputs and receipt are saved;"
      echo "   reply to your approval email with run id ${RUN_TAG} and your score ($SCORE).${RESET}";;
    409)
      # the ledger refused on purpose (run not finished on our side, or already recorded)
      echo "   ${DIM}the ledger did not record this score (HTTP 409): ${MSG:-no reason given}"
      echo "   your outputs and receipt are saved; rerun score.sh later to record the score${RESET}";;
    *)
      echo "   ${DIM}(could not reach the ledger to record $SCORE (HTTP $HTTP);"
      echo "   your outputs and receipt are saved; rerun score.sh later to record the score)${RESET}";;
  esac
  echo
fi

echo "${BOLD}   That was the public benchmark. Your documents are the real test.${RESET}"
echo "   See TackleVision on them: ${GREEN}https://tackle.ai/demo/${RESET}"
echo
