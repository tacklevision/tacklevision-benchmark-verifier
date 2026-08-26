#!/usr/bin/env python3
"""output_tree_sha256: the hash in every receipt, recomputable by anyone.

The worker that produced your outputs hashes the finished output directory
with exactly this algorithm and writes the result into receipt.json as
output_tree_sha256. score.sh runs it over the tar you downloaded and refuses
to score anything whose hash differs from the receipt.

Algorithm (unlike integrity/manifest.py, EVERY file counts, including the
.protocol stamp):
  for each file under the root (any depth):
      line = "<sha256 of file bytes>  <path relative to root, '/' separated>"
  tree hash = sha256( "\\n".join(sorted(lines)) + "\\n" )

Usage:
  tree_hash.py <dir>                 print the hash
  tree_hash.py <dir> --expect <hex>  exit 0 on match, 2 on mismatch
"""
import argparse
import hashlib
import os
import sys


def tree_sha256(root):
    entries = []
    for dirpath, _, files in os.walk(root):
        for fn in sorted(files):
            p = os.path.join(dirpath, fn)
            rel = os.path.relpath(p, root).replace(os.sep, "/")
            h = hashlib.sha256(open(p, "rb").read()).hexdigest()
            entries.append(f"{h}  {rel}")
    return hashlib.sha256(("\n".join(sorted(entries)) + "\n").encode()).hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("root", help="the unpacked outputs directory (holds .protocol and the category folders)")
    ap.add_argument("--expect", help="the receipt's output_tree_sha256; exit 2 if the tree differs")
    args = ap.parse_args()
    if not os.path.isdir(args.root):
        sys.exit(f"!! not a directory: {args.root}")
    got = tree_sha256(args.root)
    if args.expect is None:
        print(got)
        return
    if got == args.expect.strip().lower():
        print(f">> MATCH: output_tree_sha256 {got}")
        sys.exit(0)
    print(f"!! output tree hash does not match the receipt: computed {got}, receipt says {args.expect}",
          file=sys.stderr)
    sys.exit(2)


if __name__ == "__main__":
    main()
