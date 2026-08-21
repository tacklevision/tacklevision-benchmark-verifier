#!/usr/bin/env bash
# verify.sh: the whole verification, one command.
#
#   bash verify.sh --key tv-XXXXXXXX
#
# Runs all five stages end to end and can be rerun safely at any point:
# every stage picks up where it left off (downloads resume, an interrupted
# run is rejoined, scoring just recomputes).
#
# The individual stages are ordinary scripts in this folder (get_dataset.sh,
# submit.sh, score.sh); skeptics are encouraged to run and read them one by one.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; RED=$'\033[31m'; CYAN=$'\033[36m'; RESET=$'\033[0m'
TOTAL_STAGES=5
T0=$(date +%s)

usage() { echo "usage: bash verify.sh --key tv-XXXX   (the key is in your approval email)"; exit 1; }
KEY="${TV_API_KEY:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --key) KEY="${2:-}"; shift 2;;
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

fail() {
  echo
  echo "${RED}${BOLD}!! Stage $1 did not finish.${RESET}"
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
echo "    1. Check this machine            ${DIM}(seconds)${RESET}"
echo "    2. Set up the scoring toolchain  ${DIM}(2-5 min, one time)${RESET}"
echo "    3. Get the benchmark data        ${DIM}(from AllenAI, ~450 MB, one time)${RESET}"
echo "    4. Run 1,403 pages on TackleAI's GPU cluster  ${DIM}(15-20 min)${RESET}"
echo "    5. Score it yourself with AllenAI's official tool  ${DIM}(20-40 min first time)${RESET}"
echo
echo "  Every stage prints live progress. If a progress bar is moving, it is"
echo "  working. You can close this terminal and rerun the command later;"
echo "  nothing has to start over."

# ---- 1/5 ------------------------------------------------------------------
stage 1 "Checking this machine"
S1=$(date +%s)
command -v curl >/dev/null || { echo "   curl is required"; fail 1; }
# find a Python 3.10+ even when plain `python3` is an older system one
# (common on macOS: brew/python.org installs exist but are not first in PATH)
PY=""
for c in "$HERE/.python/python/bin/python3" \
         python3 python3.13 python3.12 python3.11 python3.10 \
         /opt/homebrew/bin/python3 /usr/local/bin/python3 \
         /Library/Frameworks/Python.framework/Versions/3.13/bin/python3 \
         /Library/Frameworks/Python.framework/Versions/3.12/bin/python3 \
         /Library/Frameworks/Python.framework/Versions/3.11/bin/python3 \
         /Library/Frameworks/Python.framework/Versions/3.10/bin/python3; do
  P=$(command -v "$c" 2>/dev/null || true); [ -n "$P" ] || { [ -x "$c" ] && P="$c"; }
  [ -n "${P:-}" ] || continue
  if "$P" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then
    PY="$P"; break
  fi
done

# No usable Python: offer (never force) a private, checksum-verified copy that
# lives inside this folder only. Pinned to one exact build of CPython 3.12
# from python-build-standalone (the same builds tools like uv ship).
PBS_RELEASE="20260814"; PBS_VERSION="3.12.14"
if [ -z "$PY" ]; then
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64)  PBS_ARCH="aarch64-apple-darwin";      PBS_SHA="4572133a5542f306b9bdb155da5800f9e38950cd0a98d469b832ce256fe299ea";;
    Darwin-x86_64) PBS_ARCH="x86_64-apple-darwin";       PBS_SHA="1a94c83264731e9603fbea78e57e7ca8f20e7d91eb866627ac2304621b0f6f1f";;
    Linux-x86_64)  PBS_ARCH="x86_64-unknown-linux-gnu";  PBS_SHA="3297691ae34f75fed81ac424e040145fccb0bafe8e581cd5cadbddfa1c0766c0";;
    Linux-aarch64) PBS_ARCH="aarch64-unknown-linux-gnu"; PBS_SHA="4952b18bafda1880d4ab1f86e1c348dbdb31f0e6d049e76dc5f052f2f796f1c5";;
    *) PBS_ARCH="";;
  esac
  echo "   ${RED}No Python 3.10 or newer found on this machine.${RESET}"
  if [ -n "$PBS_ARCH" ] && [ -t 0 ]; then
    echo
    echo "   Press Enter and verify.sh will download a private, checksum-verified"
    echo "   copy of Python $PBS_VERSION into this folder only (nothing is installed on"
    echo "   your system; delete this folder to remove it)."
    echo "   Or press Ctrl-C and install Python yourself (https://python.org)."
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
    echo "   Install from https://python.org or: brew install python"
    [ -t 0 ] || echo "   (running non-interactively, so verify.sh will not offer its own download)"
    fail 1
  fi
fi
echo "   ${GREEN}✓${RESET} $("$PY" -V) found at $PY, curl found  ${DIM}($(elapsed $S1))${RESET}"

# ---- 2/5 ------------------------------------------------------------------
stage 2 "Setting up the scoring toolchain (pinned versions, isolated venv)"
S2=$(date +%s)
if [ -d .venv ] && ! .venv/bin/python -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then
  echo "   (rebuilding: the existing .venv was made with an older Python)"
  rm -rf .venv
fi
[ -d .venv ] || "$PY" -m venv .venv
# shellcheck disable=SC1091
source .venv/bin/activate
PIP_LOG="$HERE/.pip_install.log"
if python3 -m pip install -q -r requirements.txt > "$PIP_LOG" 2>&1; then
  echo "   ${GREEN}✓${RESET} AllenAI's scorer + pinned dependencies ready  ${DIM}($(elapsed $S2))${RESET}"
else
  tail -5 "$PIP_LOG"; fail 2
fi

# ---- 3/5 ------------------------------------------------------------------
stage 3 "Getting the benchmark data straight from AllenAI"
echo "   ${DIM}1,410 files, ~450 MB. The progress bar below is live; interrupted"
echo "   downloads resume. Afterwards every file is hash-checked against the"
echo "   published manifest, so you know your copy is the real benchmark.${RESET}"
S3=$(date +%s)
bash get_dataset.sh || fail 3
echo "   ${GREEN}✓${RESET} official dataset on disk and proven authentic  ${DIM}($(elapsed $S3))${RESET}"

# ---- 4/5 ------------------------------------------------------------------
stage 4 "Running all 1,403 pages on TackleAI's GPU cluster"
S4=$(date +%s)
bash submit.sh "$HERE/bench_data" || fail 4
OUT_TAR=$(ls -t outputs_*.tar.gz 2>/dev/null | head -1)
[ -n "$OUT_TAR" ] || { echo "   run finished but no outputs file found"; fail 4; }
echo "   ${GREEN}✓${RESET} raw outputs + receipt downloaded  ${DIM}($(elapsed $S4))${RESET}"

# ---- 5/5 ------------------------------------------------------------------
stage 5 "Scoring on YOUR machine with AllenAI's official tool"
S5=$(date +%s)
bash score.sh "$OUT_TAR" || fail 5

echo "${DIM}  Total time: $(elapsed $T0). Run it again any time: bash verify.sh --key $KEY${RESET}"
echo
