#!/usr/bin/env bash
# fetch.sh <run_id>: check on a run and download its results when done.
# Use this if a run was interrupted; it finishes on our side and the results
# wait for 30 days.
#   TV_API_KEY=tv-... bash fetch.sh a1b2c3d4e5f6
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/client_common.sh"

KEY="${TV_API_KEY:?set TV_API_KEY (your key from the approval email)}"
RUN_ID="${1:?usage: fetch.sh <run_id>   (printed by submit.sh at start)}"

echo ">> checking on run $RUN_ID"
poll_run "$RUN_ID"
download_run "$RUN_ID" || exit 1
echo
echo "${GREEN}>> done.${RESET} Saved to this folder:"
echo "   outputs_${RUN_ID}.tar.gz   (raw model output for all $TOTAL_PAGES_TEXT pages)"
echo "   receipt_${RUN_ID}.json    (what ran, on what data, with what hashes)"
next_steps "$RUN_ID"
