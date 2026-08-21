#!/usr/bin/env python3
"""Canonical dataset manifest: the one hash both sides agree on.

generate: walk a bench_data tree, sha256 every file, emit sorted
          "<sha256>  <relpath>" lines; the MANIFEST HASH is the sha256 of
          that byte stream. Zip/tar/timestamps never matter: content only.
verify:   recompute over a local tree and compare to an expected manifest
          hash. Exit 0 match, 2 mismatch (prints per-file diff summary).

Used by: the client (prove your local copy is the official dataset before
running/scoring), the orchestrator (prove what was run), the receipt.
"""
import argparse
import hashlib
import os
import sys

# files that are part of the dataset proper; everything else is ignored so a
# user's own output trees sitting next to bench_data never break the hash
INCLUDE_EXT = (".pdf", ".jsonl")


def file_sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def manifest_lines(root):
    lines = []
    for dirpath, _, files in os.walk(root, followlinks=True):
        for fn in files:
            if not fn.endswith(INCLUDE_EXT):
                continue
            p = os.path.join(dirpath, fn)
            rel = os.path.relpath(p, root).replace(os.sep, "/")
            lines.append(f"{file_sha256(p)}  {rel}")
    return sorted(lines)


def manifest_hash(lines):
    return hashlib.sha256(("\n".join(lines) + "\n").encode()).hexdigest()


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("generate")
    g.add_argument("root")
    g.add_argument("--out", help="write full manifest here (default stdout)")
    v = sub.add_parser("verify")
    v.add_argument("root")
    v.add_argument("--expected-hash", required=True)
    v.add_argument("--expected-manifest", help="full manifest file for per-file diffs")
    h = sub.add_parser("hash", help="print only the computed manifest hash (for attestation)")
    h.add_argument("root")
    args = ap.parse_args()

    lines = manifest_lines(args.root)
    mh = manifest_hash(lines)

    if args.cmd == "hash":
        if not lines:
            print(f"!! no dataset found at {args.root} (0 files). "
                  f"Run get_dataset.sh first to download and link it.", file=sys.stderr)
            sys.exit(2)
        print(mh)
        return

    if args.cmd == "verify" and not lines:
        print(f"!! no dataset found at {args.root} (0 files). "
              f"Run get_dataset.sh first to download and link it.", file=sys.stderr)
        sys.exit(2)

    if args.cmd == "generate":
        body = "\n".join(lines) + "\n"
        if args.out:
            with open(args.out, "w") as f:
                f.write(body)
        else:
            sys.stdout.write(body)
        print(f"files: {len(lines)}", file=sys.stderr)
        print(f"MANIFEST_SHA256: {mh}", file=sys.stderr)
        return

    if mh == args.expected_hash:
        print(f">> MATCH: {len(lines)} files, manifest {mh}")
        sys.exit(0)
    print(f"!! MISMATCH: computed {mh}, expected {args.expected_hash}", file=sys.stderr)
    if args.expected_manifest and os.path.exists(args.expected_manifest):
        exp = set(open(args.expected_manifest).read().splitlines())
        got = set(lines)
        for l in sorted(exp - got)[:10]:
            print(f"   missing/changed: {l.split('  ',1)[1]}", file=sys.stderr)
        for l in sorted(got - exp)[:10]:
            print(f"   unexpected/changed: {l.split('  ',1)[1]}", file=sys.stderr)
    sys.exit(2)


if __name__ == "__main__":
    main()
