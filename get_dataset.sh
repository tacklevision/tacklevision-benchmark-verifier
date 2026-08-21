#!/usr/bin/env bash
# get_dataset.sh: download the official olmOCR-bench dataset from AllenAI at
# the exact pinned revision our published numbers use, then prove your copy
# is byte-identical to it (manifest check).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PINNED_REVISION="54a96a6fb6a2bd3b297e59869491db4d3625b711"
PINNED_MANIFEST="fded36af2edbe541ee822ffd623d192560b7b14aefdb828b62c2961e94005d51"

if [ -e "$HERE/bench_data" ] && [ ! -L "$HERE/bench_data" ]; then
  echo "!! $HERE/bench_data exists but is not the expected symlink. Move it aside and rerun"; exit 1
fi
# Use HF's classic download path, not the xet backend: xet spends one API call
# per file, and 1,410 files exceeds the API rate limit (500 per 5 min anonymous,
# 1,000 with a token) mid-download. The classic path draws on the separate
# file-download quota (3,000 per 5 min anonymous), which fits the whole dataset,
# and huggingface_hub waits out any 429 by itself. No HF account needed.
export HF_HUB_DISABLE_XET=1
DOWNLOAD_ATTEMPTS=5   # the download resumes where it left off, so retries are cheap
RETRY_WAIT_SECONDS=75
if [ ! -d "$HERE/bench_data/pdfs" ]; then
  echo ">> downloading olmOCR-bench data from AllenAI (~450 MB, one time)"
  HF_CLI=$(command -v hf || command -v huggingface-cli || true)
  [ -n "$HF_CLI" ] || { echo "!! no hf/huggingface-cli on PATH. pip install -r requirements.txt first"; exit 1; }
  ok=""
  for attempt in $(seq 1 "$DOWNLOAD_ATTEMPTS"); do
    if "$HF_CLI" download allenai/olmOCR-bench --repo-type dataset \
      --revision "$PINNED_REVISION" \
      --local-dir "$HERE/olmOCR-bench"; then ok=1; break; fi
    echo ">> download interrupted; resuming in ${RETRY_WAIT_SECONDS}s (attempt $attempt of $DOWNLOAD_ATTEMPTS)"
    sleep "$RETRY_WAIT_SECONDS"
  done
  [ -n "$ok" ] || { echo "!! download did not finish after $DOWNLOAD_ATTEMPTS attempts. Rerun this script; it resumes where it left off"; exit 1; }
  ln -sfn "$HERE/olmOCR-bench/bench_data" "$HERE/bench_data"
fi

echo ">> verifying your copy against the pinned official manifest"
python3 "$HERE/integrity/manifest.py" verify "$HERE/bench_data" \
  --expected-hash "$PINNED_MANIFEST" --expected-manifest "$HERE/integrity/official_manifest.txt"
echo ">> dataset ready: $HERE/bench_data"
