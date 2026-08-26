#!/usr/bin/env bash
# submit.sh [--fresh] [path/to/bench_data]: verify the local dataset copy
# against the pinned official manifest, run the benchmark on TackleVision's
# pool, download the raw outputs + receipt.
#
#   TV_API_KEY=tv-... bash submit.sh [bench_data]
#
# Reruns are safe and never spend a second GPU run by accident: an unfinished
# run from this folder is rejoined, a finished one is downloaded (or reported
# as already downloaded). --fresh starts a new run deliberately.
# Needs: curl, python3. Polls until the run finishes (~10 min once it starts,
# plus any queue).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/client_common.sh"

# ---- constants -------------------------------------------------------------
PINNED_MANIFEST="fded36af2edbe541ee822ffd623d192560b7b14aefdb828b62c2961e94005d51"
STATE_FILE="$HERE/.tv_last_run"     # id of the run this folder is working on
PENDING_FILE="$HERE/.tv_pending"    # client_ref of a create request in flight (idempotent retry)

KEY="${TV_API_KEY:?set TV_API_KEY to your verification key (in your approval email)}"
FRESH=""
DATA="$HERE/bench_data"
while [ $# -gt 0 ]; do
  case "$1" in
    --fresh) FRESH=1; shift;;
    -h|--help) echo "usage: TV_API_KEY=tv-... bash submit.sh [--fresh] [bench_data]"; exit 0;;
    *) DATA="$1"; shift;;
  esac
done

echo "${BOLD}>> proving your dataset copy is the official one (file-by-file check)${RESET}"
python3 "$HERE/integrity/manifest.py" verify "$DATA" --expected-hash "$PINNED_MANIFEST" \
  --expected-manifest "$HERE/integrity/official_manifest.txt" \
  || { echo "!! your copy differs from the official revision; rerun get_dataset.sh"; exit 2; }
ATTEST=$(python3 "$HERE/integrity/manifest.py" hash "$DATA")
echo "   ${GREEN}proven${RESET}: your 1,410 files are byte-identical to AllenAI's pinned revision"

RUN_ID=""
# ---- resume: never start a new run while this folder has one ---------------
if [ -z "$FRESH" ] && [ -f "$STATE_FILE" ]; then
  OLD_ID=$(tr -d '[:space:]' < "$STATE_FILE")
  http_get "$API/runs/$OLD_ID"
  case "$HTTP" in
    200)
      OLD_ST=$(echo "$BODY" | j status)
      case "$OLD_ST" in
        queued|running|verifying)
          RUN_ID="$OLD_ID"
          echo ">> found your unfinished run $RUN_ID; rejoining it (no new run needed)";;
        done)
          if already_downloaded "$OLD_ID"; then
            echo ">> your run $OLD_ID is finished and already downloaded:"
            echo "   outputs_${OLD_ID}.tar.gz and receipt_${OLD_ID}.json"
            echo "   (to start a deliberate new run instead: add --fresh)"
            next_steps "$OLD_ID"
            exit 0
          fi
          RUN_ID="$OLD_ID"
          echo ">> found your finished run $RUN_ID; downloading it (no new run needed)";;
        failed|rejected|expired)
          echo ">> your previous run $OLD_ID ended as '$OLD_ST': $(echo "$BODY" | j error)"
          echo "   starting a new run";;
        *)
          echo "!! could not make sense of the gateway's answer about your previous run $OLD_ID."
          echo "   Not starting a new run on a guess; rerun in a minute."; exit 1;;
      esac;;
    401|403)
      echo "!! your key expired or was revoked (HTTP $HTTP)."
      echo "   Your previous run $OLD_ID finishes on our side; request a new key at"
      echo "   $KEY_REQUEST_URL and rerun to fetch it."
      exit "$EXIT_KEY_REJECTED";;
    404)
      echo "!! your previous run $OLD_ID is not reachable with this key (HTTP 404)."
      echo "   If you were issued a new key since, start over deliberately with:"
      echo "   bash verify.sh --key <your key> --fresh"
      echo "   Otherwise reply to your approval email with run id $OLD_ID."
      exit "$EXIT_RUN_NOT_FOUND";;
    *)
      echo "!! could not check on your previous run $OLD_ID (HTTP $HTTP)."
      echo "   Not starting a new run on a guess; rerun in a minute."; exit 1;;
  esac
fi

# ---- create ----------------------------------------------------------------
if [ -z "$RUN_ID" ]; then
  echo "${BOLD}>> starting a verified run on TackleAI's GPU cluster${RESET}"
  # client_ref is written to disk BEFORE the request leaves, so a rerun after a
  # dropped response replays the same reference and the gateway returns the
  # run it already created instead of a second one
  REF=""
  [ -f "$PENDING_FILE" ] && REF=$(tr -d '[:space:]' < "$PENDING_FILE")
  if [ -z "$REF" ]; then
    REF=$(python3 -c 'import uuid; print(uuid.uuid4())')
    echo "$REF" > "$PENDING_FILE"
  fi
  http_post "$API/runs" "{\"mode\":\"revision\",\"client_manifest_sha256\":\"$ATTEST\",\"client_ref\":\"$REF\"}"
  MSG=$(echo "$BODY" | j error)
  case "$HTTP" in
    201|200)
      RUN_ID=$(echo "$BODY" | j run_id)
      [ -n "$RUN_ID" ] || { echo "!! the gateway answered without a run id; rerun"; exit 1; }
      echo "$RUN_ID" > "$STATE_FILE"
      rm -f "$PENDING_FILE"
      echo "   run id: ${BOLD}$RUN_ID${RESET}   ${DIM}(save this; rejoin any time with: bash fetch.sh $RUN_ID)${RESET}"
      echo "   dataset revision: $(echo "$BODY" | j dataset_revision)";;
    401|403)
      echo "!! could not start the run (HTTP $HTTP)"
      [ -n "$MSG" ] && echo "   server says: $MSG"
      echo "   your key expired or was revoked; request a new one at $KEY_REQUEST_URL"
      exit "$EXIT_KEY_REJECTED";;
    409)
      echo "!! could not start the run (HTTP 409)"
      [ -n "$MSG" ] && echo "   server says: $MSG"
      for id in $(echo "$BODY" | jlist open_runs); do
        echo "   rejoin it with: bash fetch.sh $id"
      done
      exit 1;;
    429)
      echo "!! the gateway is rate limiting; wait a minute and rerun"; exit 1;;
    000)
      echo "!! could not reach the verification gateway; check your internet connection and rerun."
      echo "   (if the request did get through, the rerun picks up that same run; nothing is duplicated)"
      exit 1;;
    *)
      echo "!! could not start the run (HTTP $HTTP)"
      [ -n "$MSG" ] && echo "   server says: $MSG"
      exit 1;;
  esac
fi

# ---- wait, then download ---------------------------------------------------
poll_run "$RUN_ID"
download_run "$RUN_ID" || exit 1
echo
echo "${GREEN}>> run complete.${RESET} Saved to this folder:"
echo "   outputs_${RUN_ID}.tar.gz   (raw model output for all $TOTAL_PAGES_TEXT pages)"
echo "   receipt_${RUN_ID}.json    (what ran, on what data, with what hashes)"
next_steps "$RUN_ID"
