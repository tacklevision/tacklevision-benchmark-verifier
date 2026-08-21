#!/usr/bin/env bash
# submit.sh [path/to/bench_data]: verify the local dataset copy against the
# pinned official manifest, run the benchmark on TackleVision's pool, download
# the raw outputs + receipt.
#
#   TV_API_KEY=tv-... bash submit.sh [bench_data]
# Needs: curl, python3. Polls until the run finishes (~15-20 min + queue).
set -euo pipefail
DEFAULT_API="https://mk7y315169.execute-api.us-east-1.amazonaws.com/v1"
API="${TV_API_URL:-$DEFAULT_API}"
KEY="${TV_API_KEY:?set TV_API_KEY to your verification key (in your approval email)}"
HERE="$(cd "$(dirname "$0")" && pwd)"
DATA="${1:-$HERE/bench_data}"
PINNED_MANIFEST="fded36af2edbe541ee822ffd623d192560b7b14aefdb828b62c2961e94005d51"
POLL_SECONDS=15
STATE_FILE="$HERE/.tv_last_run"

BOLD=$'\033[1m'; GREEN=$'\033[32m'; DIM=$'\033[2m'; RESET=$'\033[0m'
j() { python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('$1',''))"; }

echo "${BOLD}>> proving your dataset copy is the official one (file-by-file check)${RESET}"
python3 "$HERE/integrity/manifest.py" verify "$DATA" --expected-hash "$PINNED_MANIFEST" \
  --expected-manifest "$HERE/integrity/official_manifest.txt" \
  || { echo "!! your copy differs from the official revision; rerun get_dataset.sh"; exit 2; }
ATTEST=$(python3 "$HERE/integrity/manifest.py" hash "$DATA")
echo "   ${GREEN}proven${RESET}: your 1,410 files are byte-identical to AllenAI's pinned revision"

RUN_ID=""
# resume politely: if the last run from this folder is still going, rejoin it
if [ -f "$STATE_FILE" ]; then
  OLD_ID=$(cat "$STATE_FILE")
  OLD=$(curl -sf -H "x-api-key: $KEY" "$API/runs/$OLD_ID" 2>/dev/null || echo "{}")
  case "$(echo "$OLD" | j status 2>/dev/null)" in
    queued|running|verifying)
      RUN_ID="$OLD_ID"
      echo ">> found your unfinished run $RUN_ID; rejoining it (no new run needed)";;
  esac
fi

if [ -z "$RUN_ID" ]; then
  echo "${BOLD}>> starting a verified run on TackleAI's GPU cluster${RESET}"
  HTTP=$(curl -s -o /tmp/tv_create_resp.$$ -w "%{http_code}" -X POST \
          -H "x-api-key: $KEY" -H "Content-Type: application/json" \
          -d "{\"mode\":\"revision\",\"client_manifest_sha256\":\"$ATTEST\"}" "$API/runs" || echo 000)
  RESP=$(cat /tmp/tv_create_resp.$$ 2>/dev/null || true); rm -f /tmp/tv_create_resp.$$
  if [ "$HTTP" != "201" ]; then
    echo "!! could not start the run (HTTP $HTTP)"
    MSG=$(echo "${RESP:-null}" | j error 2>/dev/null || true)
    [ -n "$MSG" ] && echo "   server says: $MSG"
    case "$HTTP" in
      401|403) echo "   your key looks expired or revoked. Reply to your approval email for a fresh one.";;
      429) echo "   a previous run of yours is still open; rejoin it with: bash fetch.sh <run_id>";;
      000) echo "   could not reach the verification gateway; check your internet connection and rerun.";;
    esac
    exit 1
  fi
  RUN_ID=$(echo "$RESP" | j run_id)
  echo "$RUN_ID" > "$STATE_FILE"
  echo "   run id: ${BOLD}$RUN_ID${RESET}   ${DIM}(save this; rejoin any time with: bash fetch.sh $RUN_ID)${RESET}"
  echo "   dataset revision: $(echo "$RESP" | j dataset_revision)"
fi

echo ">> running all 1,403 pages (typically 15-20 minutes; safe to leave this open)"
START=$(date +%s)
BAR_W=24
while true; do
  S=$(curl -sf -H "x-api-key: $KEY" "$API/runs/$RUN_ID") || { sleep "$POLL_SECONDS"; continue; }
  ST=$(echo "$S" | j status)
  EL=$(( $(date +%s) - START )); MIN=$((EL/60)); SEC=$((EL%60))
  case "$ST" in
    done) printf "\r   elapsed %02d:%02d  done%-50s\n" "$MIN" "$SEC" ""; break;;
    failed|rejected|expired)
      printf "\n"; echo "!! run is '$ST': $(echo "$S" | j error)"; exit 1;;
    running)
      P=$(echo "$S" | j pages_done); T=$(echo "$S" | j pages_total)
      if [ -n "$P" ] && [ -n "$T" ] && [ "$T" -gt 0 ] 2>/dev/null; then
        FILL=$(( P * BAR_W / T ))
        BAR=""
        i=0; while [ $i -lt $BAR_W ]; do
          if [ $i -lt $FILL ]; then BAR="${BAR}█"; else BAR="${BAR}░"; fi; i=$((i+1))
        done
        printf "\r   elapsed %02d:%02d  running  %s  %s/%s pages   " "$MIN" "$SEC" "$BAR" "$P" "$T"
      else
        printf "\r   elapsed %02d:%02d  running (warming up)              " "$MIN" "$SEC"
      fi;;
    *) printf "\r   elapsed %02d:%02d  %s                        " "$MIN" "$SEC" "$ST";;
  esac
  sleep "$POLL_SECONDS"
done

echo "${BOLD}>> downloading raw outputs + signed receipt${RESET}"
curl -sf -o "outputs_${RUN_ID}.tar.gz" "$(echo "$S" | j outputs_url)"
curl -sf -o "receipt_${RUN_ID}.json" "$(echo "$S" | j receipt_url)"
rm -f "$STATE_FILE"
echo
echo "${GREEN}>> run complete.${RESET} Saved to this folder:"
echo "   outputs_${RUN_ID}.tar.gz   (raw model output for all 1,403 pages)"
echo "   receipt_${RUN_ID}.json    (what ran, on what data, with what hashes)"
echo
echo ">> Next: score it on your machine with AllenAI's official tool:"
echo
echo "   bash score.sh outputs_${RUN_ID}.tar.gz"
echo
