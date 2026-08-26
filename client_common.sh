# client_common.sh: constants and helpers shared by submit.sh, fetch.sh and
# score.sh (and the key check in verify.sh). Sourced, never run on its own.
#
# Every tunable lives here exactly once. Each one can be overridden for a
# single session with the TV_* environment variable of the same name, which is
# how the test suite runs these scripts fast; nothing here changes what the
# model does or what gets scored.
#
# Works on macOS bash 3.2 and Linux bash, with curl 7.68 or newer (no flags
# newer than that are used).

# ---- gateway ---------------------------------------------------------------
DEFAULT_API="https://nfsii7swxl.execute-api.us-east-1.amazonaws.com/v1"
API="${TV_API_URL:-$DEFAULT_API}"
KEY_REQUEST_URL="https://tackle.ai/tacklevision-benchmark/"
RESULTS_KEPT_DAYS=30            # finished runs stay downloadable this long
TOTAL_PAGES_TEXT="1,403"        # the benchmark's page count, for messages
HTTP_TIMEOUT="${TV_HTTP_TIMEOUT:-30}"                     # per API call, seconds

# ---- polling ---------------------------------------------------------------
POLL_SECONDS="${TV_POLL_SECONDS:-15}"                     # between status checks
RETRY_WARN_AFTER="${TV_RETRY_WARN_AFTER:-4}"              # failed checks in a row before the one warning line
RATE_LIMIT_BACKOFF_SECONDS="${TV_RATE_LIMIT_BACKOFF_SECONDS:-60}"   # after an HTTP 429 (or an edge block, see http_get)
MAX_QUEUED_SECONDS="${TV_MAX_QUEUED_SECONDS:-5400}"       # 90 min queued = something is wrong
# 20 min with no page progress while running. Our side watches for stalls too
# and restarts the run itself (15 min, plus a restart margin); this must stay
# ABOVE that, so the client declares a stall only when our side did not act.
STALL_SECONDS="${TV_STALL_SECONDS:-1200}"
MAX_POLL_MINUTES="${TV_MAX_POLL_MINUTES:-180}"            # absolute cap on one sitting
MAX_TOTAL_SECONDS="${TV_MAX_TOTAL_SECONDS:-$((MAX_POLL_MINUTES * 60))}"
SCORING_PHASE_MINUTES=2                                   # our packaging + own score after the last page
RUN_MINUTES_TEXT="~10 min"                                # how long one run takes once it starts

# ---- downloads -------------------------------------------------------------
DL_RETRIES="${TV_DL_RETRIES:-3}"
DL_RETRY_DELAY="${TV_DL_RETRY_DELAY:-5}"
DL_TIMEOUT="${TV_DL_TIMEOUT:-300}"

# ---- exit codes (verify.sh turns these into specific advice) ---------------
EXIT_KEY_REJECTED=3       # 401/403: the key is expired or revoked; rerunning cannot help
EXIT_RUN_NOT_FOUND=4      # 404: the run id is unknown for this key
EXIT_STUCK=5              # a wait cap fired; the run may still finish on our side

BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'
BAR_W=24
STATUS_W=60               # text width of one \r status line (78 columns with the prefix; Terminal opens at 80)

# ---- JSON helpers (python3 is required by every script anyway) -------------
j() {  # j <field>  : print one top-level field of the JSON on stdin ('' when absent/null/not JSON)
  python3 -c '
import json, sys
try:
    v = json.load(sys.stdin).get(sys.argv[1])
    print("" if v is None else v)
except Exception:
    print("")' "$1"
}
jlist() {  # jlist <field> : one line per element of a JSON list field
  python3 -c '
import json, sys
try:
    for v in (json.load(sys.stdin).get(sys.argv[1]) or []):
        print(v)
except Exception:
    pass' "$1"
}

# ---- HTTP: always capture the status code, never let curl -f hide it -------
# http_get <url> / http_post <url> <json>  -> sets HTTP (000 on transport
# failure) and BODY. Safe under set -e.
#
# The gateway itself answers 401/403 with a JSON body carrying `error`. A 403
# WITHOUT it never came from the gateway: it is the edge in front of it
# blocking the request as too frequent (typically an HTML page). That says
# nothing about the key, so it is reported and handled as a 429: back off,
# retry.
edge_block_as_429() {
  if [ "$HTTP" = "403" ] && [ -z "$(printf '%s' "$BODY" | j error)" ]; then HTTP="429"; fi
}
http_get() {
  local tmp; tmp=$(mktemp "${TMPDIR:-/tmp}/tv_http.XXXXXX")
  HTTP=$(curl -s -m "$HTTP_TIMEOUT" -o "$tmp" -w '%{http_code}' -H "x-api-key: $KEY" "$1" 2>/dev/null) || HTTP="000"
  [ -n "$HTTP" ] || HTTP="000"
  BODY=$(cat "$tmp" 2>/dev/null || true); rm -f "$tmp"
  edge_block_as_429
}
http_post() {
  local tmp; tmp=$(mktemp "${TMPDIR:-/tmp}/tv_http.XXXXXX")
  HTTP=$(curl -s -m "$HTTP_TIMEOUT" -o "$tmp" -w '%{http_code}' -X POST \
           -H "x-api-key: $KEY" -H "Content-Type: application/json" -d "$2" "$1" 2>/dev/null) || HTTP="000"
  [ -n "$HTTP" ] || HTTP="000"
  BODY=$(cat "$tmp" 2>/dev/null || true); rm -f "$tmp"
  edge_block_as_429
}

# dl <url> <out>: download with retries into <out>.part, rename on success.
# A bash loop, not --retry-all-errors, so curl 7.68 (Ubuntu 20.04) works.
dl() {
  local url="$1" out="$2" i=1
  [ -n "$url" ] || return 1
  while [ "$i" -le "$DL_RETRIES" ]; do
    if curl -sS -f -m "$DL_TIMEOUT" -o "$out.part" "$url" && mv "$out.part" "$out"; then
      return 0
    fi
    [ "$i" -lt "$DL_RETRIES" ] && sleep "$DL_RETRY_DELAY"
    i=$((i + 1))
  done
  rm -f "$out.part"
  return 1
}

# ---- messages --------------------------------------------------------------
# A run is bound to the key that started it, and that key keeps reading its
# own runs after it expires. So a 401/403 while polling means the key was
# revoked, and a new key would not reach the run: the approval email is the
# way to get it sorted.
key_rejected_mid_run() {  # key_rejected_mid_run <run_id>
  echo "!! your key was revoked while the run was in progress (HTTP $HTTP)."
  echo "   The run (id $1) finishes on our side and stays bound to the key that started it;"
  echo "   reply to your approval email with run id $1 and we will sort it out."
}
run_not_found() {  # run_not_found <run_id>
  echo "!! the gateway does not know run $1 for this key (HTTP 404);"
  echo "   reply to your approval email with run id $1 and we will sort it out."
}
next_steps() {  # next_steps <run_id>
  echo
  echo ">> Next: score it on your machine with AllenAI's official tool:"
  echo
  echo "   bash score.sh outputs_${1}.tar.gz"
  echo
}
already_downloaded() {  # already_downloaded <run_id> : outputs + receipt present and the tar is intact
  [ -f "$HERE/outputs_$1.tar.gz" ] && [ -f "$HERE/receipt_$1.json" ] \
    && tar -tzf "$HERE/outputs_$1.tar.gz" >/dev/null 2>&1
}

# ---- the poll loop, shared by submit.sh and fetch.sh -----------------------
# status_line <min> <sec> <text>: one \r-overwritten progress line, always the
# same width (78 columns), so it never wraps in an 80-column terminal and
# fully covers the previous one
status_line() { printf "\r   elapsed %02d:%02d  %-${STATUS_W}.${STATUS_W}s" "$1" "$2" "$3"; }

# poll_run <run_id>: poll until the run is done (BODY then holds the final
# JSON, return 0). Every other outcome prints why and EXITS with a code
# verify.sh understands. Queue position, the scoring phase and stalls are
# rendered honestly; the elapsed counter keeps ticking through outages.
poll_run() {
  local rid="$1" start now el min sec fails=0 st p t phase pos eta key last_key="" last_change queued_since=0 header=0 bar fill i
  start=$(date +%s); last_change=$start
  echo "   ${DIM}(safe to Ctrl-C and rerun the same command later; nothing is lost)${RESET}"
  while true; do
    http_get "$API/runs/$rid"
    now=$(date +%s); el=$((now - start)); min=$((el / 60)); sec=$((el % 60))
    case "$HTTP" in
      200) fails=0;;
      401|403) printf "\n"; key_rejected_mid_run "$rid"; exit "$EXIT_KEY_REJECTED";;
      404) printf "\n"; run_not_found "$rid"; exit "$EXIT_RUN_NOT_FOUND";;
      429)
        status_line "$min" "$sec" "the gateway is rate limiting; next check in ${RATE_LIMIT_BACKOFF_SECONDS}s"
        sleep "$RATE_LIMIT_BACKOFF_SECONDS"; continue;;
      *)
        fails=$((fails + 1))
        if [ "$fails" -eq "$RETRY_WARN_AFTER" ]; then
          printf "\n"
          echo "   gateway unreachable, still retrying (Ctrl-C is safe; rejoin later with: bash fetch.sh $rid)"
        fi
        status_line "$min" "$sec" "waiting for the gateway (HTTP $HTTP)";;
    esac
    if [ "$HTTP" = "200" ]; then
      st=$(echo "$BODY" | j status); p=$(echo "$BODY" | j pages_done); t=$(echo "$BODY" | j pages_total)
      phase=$(echo "$BODY" | j phase)
      # the queue clock measures ONE stay in the queue: a run that was running
      # and is queued again (our side requeued it) starts a fresh one
      [ "$st" = "queued" ] || queued_since=0
      case "$st" in
        done) status_line "$min" "$sec" "done"; printf "\n"; return 0;;
        failed|rejected|expired)
          printf "\n"; echo "!! run $rid is '$st': $(echo "$BODY" | j error)"; exit 1;;
        queued)
          [ "$queued_since" -gt 0 ] || queued_since=$now
          pos=$(echo "$BODY" | j queue_position); eta=$(echo "$BODY" | j eta_minutes)
          if [ -n "$pos" ] && [ -n "$eta" ] && [ "$pos" -ge 1 ] 2>/dev/null; then
            status_line "$min" "$sec" "queued: $((pos - 1)) run(s) ahead, yours starts in ~$eta min"
          else
            status_line "$min" "$sec" "queued (waiting for a free slot on our side)"
          fi
          if [ $((now - queued_since)) -gt "$MAX_QUEUED_SECONDS" ]; then
            printf "\n"
            echo "!! run $rid has been queued for $(( (now - queued_since) / 60 )) min, longer than it ever should be."
            echo "   It is still queued on our side. Check on it later with: bash fetch.sh $rid"
            echo "   or reply to your approval email with run id $rid."
            exit "$EXIT_STUCK"
          fi;;
        running)
          if [ "$header" -eq 0 ]; then
            printf "\n"
            echo ">> running all $TOTAL_PAGES_TEXT pages ($RUN_MINUTES_TEXT once it starts; safe to leave this open)"
            header=1
          fi
          if [ "$phase" = "scoring" ]; then
            status_line "$min" "$sec" "running ${p:-?}/${t:-?} pages (packaging + our own score, ~$SCORING_PHASE_MINUTES min)"
          elif [ -n "$p" ] && [ -n "$t" ] && [ "$t" -gt 0 ] 2>/dev/null; then
            fill=$((p * BAR_W / t)); bar=""; i=0
            while [ "$i" -lt "$BAR_W" ]; do
              if [ "$i" -lt "$fill" ]; then bar="${bar}#"; else bar="${bar}."; fi; i=$((i + 1))
            done
            status_line "$min" "$sec" "running  $bar  $p/$t pages"
          else
            status_line "$min" "$sec" "running (warming up)"
          fi;;
        *) status_line "$min" "$sec" "${st:-waiting}";;
      esac
      key="$st/$p/$t/$phase"
      if [ "$key" != "$last_key" ]; then last_key="$key"; last_change=$now; fi
      if [ "$st" = "running" ] && [ $((now - last_change)) -gt "$STALL_SECONDS" ]; then
        printf "\n"
        echo "!! no page progress for $(( (now - last_change) / 60 )) min (stalled at ${p:-?}/${t:-?} pages)."
        echo "   Check on run $rid later with: bash fetch.sh $rid"
        echo "   or reply to your approval email with run id $rid."
        exit "$EXIT_STUCK"
      fi
    fi
    if [ "$el" -gt "$MAX_TOTAL_SECONDS" ]; then
      printf "\n"
      echo "!! run appears stuck; reply to your approval email with run id $rid"
      echo "   (it may still finish on our side; check later with: bash fetch.sh $rid)"
      exit "$EXIT_STUCK"
    fi
    sleep "$POLL_SECONDS"
  done
}

# download_run <run_id>: fetch outputs + receipt of the finished run in BODY.
download_run() {
  local rid="$1"
  echo "${BOLD}>> downloading raw outputs + receipt${RESET}"
  if dl "$(echo "$BODY" | j outputs_url)" "$HERE/outputs_${rid}.tar.gz" \
     && dl "$(echo "$BODY" | j receipt_url)" "$HERE/receipt_${rid}.json"; then
    return 0
  fi
  echo "!! download failed. Your run $rid is finished and kept for $RESULTS_KEPT_DAYS days; fetch it with: bash fetch.sh $rid"
  return 1
}
