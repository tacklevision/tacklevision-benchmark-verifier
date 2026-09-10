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
SCORE_T0=$(date +%s)   # scoring started; the verdict shows how long it took

# ---- constants -------------------------------------------------------------
PINNED_MANIFEST="fded36af2edbe541ee822ffd623d192560b7b14aefdb828b62c2961e94005d51"
GALLERY_SAMPLES=12
CLAIM_TEXT="86.1 to 86.6"          # the published claim being checked
SCORER_TESTS_TEXT="~8,400"         # how many individual tests the scorer runs, for the [FAIL] note
FAIL_SHARE_TEXT="roughly 1 in 7"   # the share of them that fails at the published score (100 - ~86 percent)
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
# said now, while they are still reading: a passing run prints over a thousand
# [FAIL] lines, and every tester so far read them as the tool breaking
echo "   ${BOLD}About the [FAIL] lines you are about to see.${RESET} The scorer prints one for every"
echo "   individual test that does not pass. At the published score $FAIL_SHARE_TEXT of its"
echo "   $SCORER_TESTS_TEXT tests fail, so well over a thousand [FAIL] lines will scroll past."
echo "   That is what a passing score looks like. It is not an error and nothing is wrong."
echo

# stdout (summary + per-test results) is preserved verbatim for inspection;
# the scorer's live progress stays on screen
python3 -m olmocr.bench.benchmark --dir "$STAGE" | tee "$SCORER_LOG"

# every verification counts: record the score on the independent-run ledger
# (only for real gateway runs: needs your key and this run's receipt). It happens
# before the verdict and the prompt below, so a Ctrl-C at the prompt still counts.
SCORE=$(tr '\r' '\n' < "$SCORER_LOG" | grep "average of per-JSONL scores" | tail -1 \
        | grep -oE "[0-9]+\.[0-9]+" | head -1 || true)
if [ -n "${TV_API_KEY:-}" ] && [ -n "$SCORE" ] && [ -f "$HERE/receipt_${RUN_TAG}.json" ]; then
  KEY="$TV_API_KEY"
  http_post "$API/runs/${RUN_TAG}/result" "{\"score\": $SCORE}"
  MSG=$(echo "$BODY" | j error)
  case "$HTTP" in
    200) echo "   ${DIM}Your score ($SCORE) is recorded on the independent-run ledger. Thank you.${RESET}";;
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
fi

# the same numbers, readable: the verdict, with this run's timing and provenance
# inside the frame so nothing important trails below it
python3 "$HERE/protocol/verdict.py" "$SCORER_LOG" ${RECEIPT:+--receipt "$RECEIPT"} \
  --scoring-started "$SCORE_T0" ${TV_RUN_STARTED:+--started "$TV_RUN_STARTED"} || true

# ---- the last things on screen ---------------------------------------------
# The gallery (real benchmark pages next to what the model read from them) is the
# most persuasive thing this run produced, and a bare file path gets ignored. So
# when there is a person at the terminal, offer to open it. Not a TTY (piped,
# CI, a log): print the path and move on, never block.
open_in_browser() {  # best effort and quiet; returns 1 when nothing here can open a file
  case "$(uname -s)" in
    Darwin) command -v open >/dev/null 2>&1 && open "$1" ;;
    *) if command -v xdg-open >/dev/null 2>&1; then xdg-open "$1" >/dev/null 2>&1
       elif command -v wslview >/dev/null 2>&1; then wslview "$1" >/dev/null 2>&1
       else return 1; fi ;;
  esac
}
echo
if [ -f "$GALLERY" ]; then
  if [ -t 0 ] && [ -t 1 ]; then
    printf "   Open the %s tested pages next to what the model read from them? [Y/n] " "$GALLERY_SAMPLES"
    read -r ans || ans=""
    case "$ans" in
      [nN]*) echo "   ${DIM}When you want it, open this in a browser: $GALLERY${RESET}";;
      *) open_in_browser "$GALLERY" && echo "   ${DIM}opened in your browser${RESET}" \
           || echo "   ${DIM}No browser could be opened from here. Open this file yourself: $GALLERY${RESET}";;
    esac
  else
    echo "   See what was tested, page by page (opens in a browser): ${GREEN}$GALLERY${RESET}"
  fi
  echo
fi
if [ -n "${TV_RUN_STARTED:-}" ]; then   # only when verify.sh ran the whole thing
  echo "   ${DIM}Run it again any time: bash verify.sh --key <your key>"
  echo "   (this starts a new run; add --fresh to be explicit)${RESET}"
  echo
fi
echo "${BOLD}   That was the public benchmark. Your documents are the real test.${RESET}"
echo "   See TackleVision on them: ${GREEN}$DEMO_URL${RESET}"
echo
