#!/usr/bin/env bash
# fetch.sh <run_id>: check on a run and download its results when done.
# Use this if a run was interrupted; it finishes server-side and results
# wait for 30 days.
#   TV_API_KEY=tv-... bash fetch.sh a1b2c3d4e5f6
set -euo pipefail
DEFAULT_API="https://mk7y315169.execute-api.us-east-1.amazonaws.com/v1"
API="${TV_API_URL:-$DEFAULT_API}"
KEY="${TV_API_KEY:?set TV_API_KEY (your key from the approval email)}"
RUN_ID="${1:?usage: fetch.sh <run_id>   (printed by submit.sh at start)}"

j() { python3 -c "import json,sys;print(json.load(sys.stdin).get('$1',''))"; }

while true; do
  S=$(curl -sf -H "x-api-key: $KEY" "$API/runs/$RUN_ID") \
    || { echo "!! cannot reach the run (wrong id? wrong key?)"; exit 1; }
  ST=$(echo "$S" | j status)
  case "$ST" in
    done) break;;
    failed|rejected|expired) echo "!! run is '$ST': $(echo "$S" | j error)"; exit 1;;
    *) P=$(echo "$S" | j pages_done); T=$(echo "$S" | j pages_total)
       [ -n "$P" ] && [ -n "$T" ] && PROG=" ($P/$T pages)" || PROG=""
       echo "   $(date +%H:%M:%S) status: $ST$PROG"; sleep 30;;
  esac
done

echo ">> downloading outputs + receipt"
curl -sf -o "outputs_${RUN_ID}.tar.gz" "$(echo "$S" | j outputs_url)"
curl -sf -o "receipt_${RUN_ID}.json" "$(echo "$S" | j receipt_url)"
echo
echo ">> done. Score locally with AllenAI's official tool:"
echo
echo "   bash score.sh outputs_${RUN_ID}.tar.gz"
echo
