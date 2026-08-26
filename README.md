# Reproduce our olmOCR-bench numbers

You verify three things yourself, on your machine:
1. the test data is AllenAI's official olmOCR-bench, byte-for-byte (sha256 manifest),
2. our model produced the outputs (run on our GPU cluster; the receipt's
   `output_tree_sha256` is recomputed over what you downloaded before anything is scored),
3. the score, computed by YOU with AllenAI's official scorer. We never touch it.

Needs: Linux or macOS (Windows: WSL), ~10 GB disk, internet. No GPU.
Python 3.12 or newer if you have it (on Ubuntu/Debian/WSL also `python3-venv`:
`sudo apt install python3.12 python3.12-venv`); if not, verify.sh offers to
fetch a private, checksum-verified copy into its own folder (asks first,
touches nothing system-wide). A verification key is free: request one at
https://tackle.ai/tacklevision-benchmark/ (usually approved within one
business day, valid for 7 days; expired keys are re-requestable with the same
form).

## The one-command version

```bash
git clone --branch v1.0.0 --depth 1 https://github.com/tacklevision/tacklevision-benchmark-verifier
cd tacklevision-benchmark-verifier
git rev-parse HEAD     # must print the commit shown in your approval email
bash verify.sh --key <your key from the approval email>
```

The clone is pinned to release `v1.0.0`; the `git rev-parse HEAD` line lets you
check that what you are about to run is exactly the audited commit named in
your approval email, not whatever a branch points at today.

That runs the whole thing with live progress at every step: a check of your
machine and your key, the hash-pinned toolchain install, the official dataset
from AllenAI (~450 MB, hash-proven against the published manifest), a full
1,403-page run on our GPU cluster (~10 min once it starts, plus any queue;
your position and ETA are shown while you wait), and finally AllenAI's
official scorer on your machine (first time 20-40 min while its math-render
cache builds; repeats take minutes). While scoring runs it writes a gallery of
sample benchmark pages next to what the model read from each, rendered from
your verified local copies.

First run: roughly 60-90 minutes, nearly all unattended. Interrupt anything,
rerun the same command, every stage resumes where it left off: an unfinished
run is rejoined and a finished one is downloaded, never repeated by accident
(`--fresh` starts a new run deliberately). Expect a final score between
**86.1 and 86.6**; differences under a point are noise. Got something else?
Tell us, we want to know.

## No key? Re-score our published run

`published_run/` contains the raw per-page outputs of a real run through the
identical inference protocol (same `.protocol` stamp) with its receipt. After
the step-by-step setup below, anyone can check that our published outputs
really score 86+ under the official scorer, no key involved; score.sh first
recomputes the receipt's `output_tree_sha256` over the tar and refuses to score
a tree that does not match:

```bash
bash score.sh published_run/outputs.tar.gz
```

## Step-by-step (what verify.sh does, one script at a time)

Skeptics are encouraged to run and read the stages individually:

```bash
python3 -m venv .venv && source .venv/bin/activate   # Python 3.12 or newer
pip install --require-hashes -r requirements.lock   # hash-pinned scorer toolchain
bash get_dataset.sh                  # official dataset + manifest proof
bash submit.sh bench_data            # attested run on our GPU cluster
bash score.sh outputs_<run_id>.tar.gz   # receipt check, then AllenAI's scorer, your machine
```

If chromium fails to launch during scoring, run
`sudo .venv/bin/python -m playwright install-deps chromium` once, then rerun.
Lost track of a run? `bash fetch.sh <run_id>` rejoins it; finished runs stay
downloadable for 30 days.

## What's in this repo

| file | role |
|---|---|
| `verify.sh` | the whole verification, one command (calls the scripts below) |
| `submit.sh` / `score.sh` / `fetch.sh` | run, score, rejoin |
| `client_common.sh` | the constants and helpers those three share (every tunable, once) |
| `get_dataset.sh` | pinned dataset download + manifest proof |
| `integrity/manifest.py` + `integrity/official_manifest.txt` | the dataset integrity anchor, recompute it yourself |
| `integrity/tree_hash.py` | recomputes a receipt's `output_tree_sha256` over the downloaded outputs (the same algorithm our side runs) |
| `integrity/check_disjoint.py` | the train/test contamination gate we ran before training |
| `protocol/` (prompt.txt, linearize.py, run_pages.py) | the protocol itself: verbatim prompt, JSON-to-markdown converter, page runner (temp 0, 2400 px renders). run_pages.py is the same code our side runs |
| `protocol/verdict.py` / `protocol/make_gallery.py` | presentation only: readable verdict over the scorer's saved output, sample-page gallery |
| `reproduce.sh` | direct-endpoint mode (runs the whole pipeline yourself against any OpenAI-compatible endpoint; used internally and kept for transparency) |
| `requirements.txt` / `requirements.lock` | what the toolchain needs / the same, hash-pinned (what verify.sh installs) |
| `results/` | logs of our own published runs |
| `published_run/` | raw outputs + receipt of a real run, re-scorable by anyone |

## Compare other models with the identical protocol

`reproduce.sh` runs the exact same prompt, rendering, decoding, in-flight cap
and official scoring against ANY OpenAI-compatible endpoint:

```bash
bash reproduce.sh <model-name> --endpoint https://<any-openai-compatible-api> --key <their key>
```

Same harness, same judge, your choice of model. We encourage it.

Licensed under Apache-2.0 (see LICENSE).
