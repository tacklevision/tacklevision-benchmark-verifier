# Reproduce our olmOCR-bench numbers

You verify three things yourself, on your machine:
1. the test data is AllenAI's official olmOCR-bench, byte-for-byte (sha256 manifest),
2. our model produced the outputs (run on our GPU cluster, receipt included),
3. the score, computed by YOU with AllenAI's official scorer. We never touch it.

Needs: Linux or macOS (Windows: WSL), ~10 GB disk, internet. No GPU. Python
3.10+ if you have it; if not, verify.sh offers to fetch a private, checksum-
verified copy into its own folder (asks first, touches nothing system-wide).
A verification key is free: request one at https://tackle.ai/tacklevision-benchmark/
(usually approved within one business day, valid for 24 hours; expired keys
are re-requestable with the same form).

## The one-command version

```bash
git clone https://github.com/tacklevision/tacklevision-benchmark-verifier
cd tacklevision-benchmark-verifier
bash verify.sh --key <your key from the approval email>
```

That runs the whole thing with live progress at every step: environment
check, pinned toolchain install, the official dataset from AllenAI (~450 MB,
hash-proven against the published manifest), a full 1,403-page run on our GPU
cluster (15-20 min), and finally AllenAI's official scorer on your machine
(first time 20-40 min while its math-render cache builds; repeats take
minutes). While scoring runs it opens a gallery of sample benchmark pages
next to what the model read from each, rendered from your verified local
copies.

First run: roughly 60-90 minutes, nearly all unattended. Interrupt anything,
rerun the same command, every stage resumes where it left off. Expect a final
score between **86.1 and 86.6**; differences under a point are noise. Got
something else? Tell us, we want to know.

## No key? Re-score our published run

`published_run/` contains the raw per-page outputs of a real run through this
exact pipeline (2026-08-19, receipt included). After the step-by-step setup
below, anyone can check that our published outputs really score 86+ under the
official scorer, no key involved:

```bash
bash score.sh published_run/outputs.tar.gz
```

## Step-by-step (what verify.sh does, one script at a time)

Skeptics are encouraged to run and read the stages individually:

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt      # pinned scorer toolchain
bash get_dataset.sh                  # official dataset + manifest proof
bash submit.sh bench_data            # attested run on our GPU cluster
bash score.sh outputs_<run_id>.tar.gz   # AllenAI's scorer, your machine
```

If chromium fails to launch during scoring, run `sudo python3 -m playwright
install-deps chromium` once, then rerun.

## What's in this repo

| file | role |
|---|---|
| `verify.sh` | the whole verification, one command (calls the scripts below) |
| `submit.sh` / `score.sh` / `fetch.sh` | run, score, rejoin |
| `get_dataset.sh` | pinned dataset download + manifest proof |
| `integrity/manifest.py` + `integrity/official_manifest.txt` | the integrity anchor, recompute it yourself |
| `protocol/` (prompt.txt, linearize.py, run_pages.py) | the exact protocol: verbatim prompt, JSON-to-markdown converter, page runner (temp 0, 2400 px renders). run_pages.py is the same code our side runs |
| `protocol/verdict.py` / `protocol/make_gallery.py` | presentation only: readable verdict over the scorer's saved output, sample-page gallery |
| `reproduce.sh` | direct-endpoint mode (runs the whole pipeline yourself against an endpoint URL; used internally and kept for transparency) |
| `check_disjoint.py` | the train/test contamination gate we ran before training |
| `results/` | logs of our own published runs |
| `published_run/` | raw outputs + receipt of a real run, re-scorable by anyone |

## Compare other models with the identical protocol

`reproduce.sh` runs the exact same prompt, rendering, decoding, and official
scoring against ANY OpenAI-compatible endpoint:

```bash
bash reproduce.sh <model-name> --endpoint https://<any-openai-compatible-api> --key <their key>
```

Same harness, same judge, your choice of model. We encourage it.

Licensed under Apache-2.0 (see LICENSE).
