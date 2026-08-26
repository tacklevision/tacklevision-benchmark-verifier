#!/usr/bin/env bash
# verify.sh: the whole verification, one command.
#
#   bash verify.sh --key tv-XXXXXXXX            (add --fresh for a deliberate new run)
#
# Runs all five stages end to end and can be rerun safely at any point:
# every stage picks up where it left off (downloads resume, an interrupted
# run is rejoined, a finished run is downloaded instead of repeated, scoring
# just recomputes).
#
# The individual stages are ordinary scripts in this folder (get_dataset.sh,
# submit.sh, score.sh); skeptics are encouraged to run and read them one by one.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
# shellcheck disable=SC1091
. "$HERE/client_common.sh"

# ---- constants -------------------------------------------------------------
TOTAL_STAGES=5
PY_MIN_MAJOR=3                         # the pinned scorer (olmocr 0.4.27) needs 3.11+
PY_MIN_MINOR=11
# the private CPython offered when no usable Python exists: one exact build of
# python-build-standalone (the same builds tools like uv ship)
PBS_RELEASE="20260814"; PBS_VERSION="3.12.14"
STATE_FILE="$HERE/.tv_last_run"
PIP_LOG="$HERE/.pip_install.log"
PIP_ERROR_LINES=5

CYAN=$'\033[36m'
T0=$(date +%s)

usage() { echo "usage: bash verify.sh --key tv-XXXX [--fresh]   (the key is in your approval email)"; exit 1; }
KEY="${TV_API_KEY:-}"
FRESH_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --key) KEY="${2:-}"; shift 2;;
    --fresh) FRESH_ARG=1; shift;;
    -h|--help) usage;;
    *) echo "unknown option: $1"; usage;;
  esac
done
[ -n "$KEY" ] || usage
export TV_API_KEY="$KEY"

elapsed() { local s=$(( $(date +%s) - $1 )); printf "%d:%02d" $((s/60)) $((s%60)); }

stage() {  # stage <n> <title>
  echo
  echo "${BOLD}${CYAN}[$1/$TOTAL_STAGES] $2${RESET}"
}

py_ok() {  # py_ok <interpreter> : at least PY_MIN
  "$1" -c "import sys; sys.exit(0 if sys.version_info >= ($PY_MIN_MAJOR, $PY_MIN_MINOR) else 1)" 2>/dev/null
}

fail() {  # fail <stage> [exit code of the stage]
  local code="${2:-1}"
  echo
  echo "${RED}${BOLD}!! Stage $1 did not finish.${RESET}"
  if [ "$code" = "$EXIT_KEY_REJECTED" ]; then
    echo "   Your key is expired or revoked, so running the same command again cannot help."
    echo "   Request a new key at $KEY_REQUEST_URL (same form), then run"
    echo "   this command with the new key; everything already on disk is reused:"
    echo
    echo "   bash verify.sh --key <new key>"
    echo
    exit "$EXIT_KEY_REJECTED"
  fi
  echo "   Nothing is lost. Fix the message above if it names a fix, then rerun"
  echo "   the exact same command; every stage resumes where it left off:"
  echo
  echo "   bash verify.sh --key $KEY"
  echo
  exit 1
}

echo
echo "${BOLD}  TACKLEVISION BENCHMARK · INDEPENDENT VERIFICATION${RESET}"
echo "${DIM}  ────────────────────────────────────────────────────────────${RESET}"
echo "  Five stages, all automatic. First run: roughly 60-90 minutes total,"
echo "  nearly all of it unattended. Reruns are much faster."
echo
echo "    1. Check this machine and your key   ${DIM}(seconds)${RESET}"
echo "    2. Set up the scoring toolchain      ${DIM}(2-5 min, one time)${RESET}"
echo "    3. Get the benchmark data            ${DIM}(from AllenAI, ~450 MB, one time)${RESET}"
echo "    4. Run $TOTAL_PAGES_TEXT pages on TackleAI's GPU cluster  ${DIM}($RUN_MINUTES_TEXT once it starts, plus any queue)${RESET}"
echo "    5. Score it yourself with AllenAI's official tool  ${DIM}(20-40 min first time)${RESET}"
echo
echo "  Every stage prints live progress. If a progress bar is moving, it is"
echo "  working. You can close this terminal and rerun the command later;"
echo "  nothing has to start over and no run is ever repeated by accident."

# ---- 1/5 ------------------------------------------------------------------
stage 1 "Checking this machine and your key"
S1=$(date +%s)
command -v curl >/dev/null || { echo "   curl is required"; fail 1; }

# the key first: a dead key must not cost anyone a toolchain install and a
# 450 MB download before they find out
http_get "$API/runs/preflight"
case "$HTTP" in
  200|204|404) echo "   ${GREEN}✓${RESET} key accepted by the gateway";;
  401|403)
    echo "   ${RED}key expired or revoked, request a new one at $KEY_REQUEST_URL${RESET}"
    fail 1 "$EXIT_KEY_REJECTED";;
  429) echo "   the gateway is rate limiting; wait a minute and rerun"; fail 1;;
  000) echo "   could not reach the verification gateway; check your internet connection and rerun."; fail 1;;
  *)   echo "   unexpected answer from the gateway (HTTP $HTTP); wait a minute and rerun"; fail 1;;
esac

# find a Python >= PY_MIN. Versioned names come BEFORE bare python3 so a
# deadsnakes/brew install is found even when the system python3 is older
# (common on Ubuntu 22.04 and older WSL images; on macOS brew/python.org
# installs exist but are not first in PATH). 3.12 and 3.11 first: the pinned
# scorer's wheels are built for them.
PY=""
for c in "$HERE/.python/python/bin/python3" \
         python3.12 python3.11 python3.13 python3 \
         /opt/homebrew/bin/python3 /usr/local/bin/python3 \
         /Library/Frameworks/Python.framework/Versions/3.12/bin/python3 \
         /Library/Frameworks/Python.framework/Versions/3.11/bin/python3 \
         /Library/Frameworks/Python.framework/Versions/3.13/bin/python3; do
  P=$(command -v "$c" 2>/dev/null || true); [ -n "$P" ] || { [ -x "$c" ] && P="$c"; }
  [ -n "${P:-}" ] || continue
  if py_ok "$P"; then PY="$P"; break; fi
done

# No usable Python: offer (never force) a private, checksum-verified copy that
# lives inside this folder only.
if [ -z "$PY" ]; then
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64)  PBS_ARCH="aarch64-apple-darwin";      PBS_SHA="4572133a5542f306b9bdb155da5800f9e38950cd0a98d469b832ce256fe299ea";;
    Darwin-x86_64) PBS_ARCH="x86_64-apple-darwin";       PBS_SHA="1a94c83264731e9603fbea78e57e7ca8f20e7d91eb866627ac2304621b0f6f1f";;
    Linux-x86_64)  PBS_ARCH="x86_64-unknown-linux-gnu";  PBS_SHA="3297691ae34f75fed81ac424e040145fccb0bafe8e581cd5cadbddfa1c0766c0";;
    Linux-aarch64) PBS_ARCH="aarch64-unknown-linux-gnu"; PBS_SHA="4952b18bafda1880d4ab1f86e1c348dbdb31f0e6d049e76dc5f052f2f796f1c5";;
    *) PBS_ARCH="";;
  esac
  echo "   ${RED}No Python $PY_MIN_MAJOR.$PY_MIN_MINOR or newer found on this machine.${RESET}"
  if [ -n "$PBS_ARCH" ] && [ -t 0 ]; then
    echo
    echo "   Press Enter and verify.sh will download a private, checksum-verified"
    echo "   copy of Python $PBS_VERSION into this folder only (nothing is installed on"
    echo "   your system; delete this folder to remove it)."
    echo "   Or press Ctrl-C and install Python $PY_MIN_MAJOR.$PY_MIN_MINOR or 3.12 yourself (https://python.org)."
    read -r _
    PBS_FILE="cpython-${PBS_VERSION}+${PBS_RELEASE}-${PBS_ARCH}-install_only.tar.gz"
    PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_RELEASE}/${PBS_FILE}"
    echo "   downloading $PBS_FILE"
    echo "   ${DIM}from $PBS_URL${RESET}"
    TMP_TGZ="$HERE/.python_download.tar.gz"
    curl -L --progress-bar -o "$TMP_TGZ" "$PBS_URL" || { echo "   download failed; rerun to retry"; fail 1; }
    GOT_SHA=$( (sha256sum "$TMP_TGZ" 2>/dev/null || shasum -a 256 "$TMP_TGZ") | awk '{print $1}')
    if [ "$GOT_SHA" != "$PBS_SHA" ]; then
      rm -f "$TMP_TGZ"
      echo "   ${RED}checksum mismatch (got $GOT_SHA); refusing to use it.${RESET} Rerun to retry."
      fail 1
    fi
    echo "   checksum verified: $PBS_SHA"
    rm -rf "$HERE/.python" && mkdir -p "$HERE/.python"
    tar -xzf "$TMP_TGZ" -C "$HERE/.python" && rm -f "$TMP_TGZ"
    PY="$HERE/.python/python/bin/python3"
    [ -x "$PY" ] || { echo "   extraction failed; rerun to retry"; fail 1; }
  else
    echo "   Install Python $PY_MIN_MAJOR.$PY_MIN_MINOR or 3.12 from https://python.org, or: brew install python@3.12"
    echo "   Ubuntu/Debian/WSL: sudo apt install python3.12 python3.12-venv"
    [ -t 0 ] || echo "   (running non-interactively, so verify.sh will not offer its own download)"
    fail 1
  fi
fi
echo "   ${GREEN}✓${RESET} $("$PY" -V) found at $PY, curl found  ${DIM}($(elapsed $S1))${RESET}"

# ---- 2/5 ------------------------------------------------------------------
stage 2 "Setting up the scoring toolchain (pinned versions, isolated venv)"
S2=$(date +%s)
venv_ok() {  # complete, new enough, pip importable; anything else is rebuilt
  [ -f .venv/bin/activate ] && py_ok .venv/bin/python \
    && .venv/bin/python -m pip --version >/dev/null 2>&1
}
if [ -d .venv ] && ! venv_ok; then
  echo "   (rebuilding: the existing .venv is incomplete or was made with an older Python)"
  rm -rf .venv
fi
if [ ! -d .venv ]; then
  # build in .venv.tmp and rename, so an interrupted creation never leaves a
  # half venv that the next run trips over
  rm -rf .venv.tmp
  if ! "$PY" -m venv .venv.tmp; then
    rm -rf .venv.tmp
    echo "   ${RED}Could not create the Python environment.${RESET}"
    echo "   Ubuntu/Debian/WSL: sudo apt install python3-venv   (then rerun the same command)"
    fail 2
  fi
  mv .venv.tmp .venv
fi
# activate by hand rather than sourcing bin/activate: that script hardcodes
# the path the venv was created at (.venv.tmp), not the one it lives at now
export VIRTUAL_ENV="$HERE/.venv"
export PATH="$VIRTUAL_ENV/bin:$PATH"
unset PYTHONHOME 2>/dev/null || true
hash -r 2>/dev/null || true
# every package hash-pinned (requirements.lock, generated with pip-compile on
# Python 3.12): what you install is exactly what our published numbers used
if python3 -m pip install -q --no-color --require-hashes -r requirements.lock > "$PIP_LOG" 2>&1; then
  echo "   ${GREEN}✓${RESET} AllenAI's scorer + hash-pinned dependencies ready  ${DIM}($(elapsed $S2))${RESET}"
else
  echo "   ${RED}pip could not install the pinned toolchain.${RESET} What it reported:"
  grep -E '^\S*ERROR' "$PIP_LOG" | head -"$PIP_ERROR_LINES" | sed 's/^/   /' || true
  echo "   full log: $PIP_LOG"
  fail 2
fi
# the scorer renders math in headless chromium; make sure it can launch NOW,
# before any GPU time is spent (idempotent: instant no-op once installed)
python3 -m playwright install chromium >/dev/null 2>&1 || true
python3 - <<'PY' || { echo "   ${RED}chromium cannot launch.${RESET} On minimal Linux, missing OS libraries are the usual cause:"; \
  echo "   sudo $HERE/.venv/bin/python -m playwright install-deps chromium   (then rerun the same command)"; fail 2; }
from playwright.sync_api import sync_playwright
with sync_playwright() as p:
    p.chromium.launch(headless=True).close()
PY
echo "   ${GREEN}✓${RESET} scorer's browser launches"

# ---- 3/5 ------------------------------------------------------------------
stage 3 "Getting the benchmark data straight from AllenAI"
echo "   ${DIM}1,410 files, ~450 MB. The progress bar below is live; interrupted"
echo "   downloads resume. Afterwards every file is hash-checked against the"
echo "   published manifest, so you know your copy is the real benchmark.${RESET}"
S3=$(date +%s)
bash get_dataset.sh || fail 3 $?
echo "   ${GREEN}✓${RESET} official dataset on disk and proven authentic  ${DIM}($(elapsed $S3))${RESET}"

# ---- 4/5 ------------------------------------------------------------------
stage 4 "Running all $TOTAL_PAGES_TEXT pages on TackleAI's GPU cluster"
S4=$(date +%s)
bash submit.sh ${FRESH_ARG:+--fresh} "$HERE/bench_data" || fail 4 $?
RUN_ID=$(tr -d '[:space:]' < "$STATE_FILE" 2>/dev/null || true)
OUT_TAR="outputs_${RUN_ID}.tar.gz"
[ -n "$RUN_ID" ] && [ -f "$OUT_TAR" ] || { echo "   run finished but $OUT_TAR is not here"; fail 4; }
echo "   ${GREEN}✓${RESET} raw outputs + receipt downloaded  ${DIM}($(elapsed $S4))${RESET}"

# ---- 5/5 ------------------------------------------------------------------
stage 5 "Scoring on YOUR machine with AllenAI's official tool"
S5=$(date +%s)
bash score.sh "$OUT_TAR" || fail 5 $?
# only now is this run finished from this folder's point of view: a rerun
# before this line re-downloads or re-scores the same run, never a new one
rm -f "$STATE_FILE"

echo "${DIM}  Total time: $(elapsed $T0). Run it again any time: bash verify.sh --key $KEY"
echo "  (a deliberate new run: bash verify.sh --key $KEY --fresh)${RESET}"
echo
