#!/usr/bin/env python3
"""Checks the named segmentation cases (data/named-cases.tsv) against the shipped segmenter.

  python3 named_cases.py         (expects work/segcli; build it with cli/build.sh)

Prints each case whose segmentation differs and exits non-zero if any do. Takes seconds — run it
before any segmentation change goes up, alongside the held2k / lyrics numbers.
"""
import os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
cases = []
for line in open(os.path.join(HERE, "data", "named-cases.tsv"), encoding="utf-8"):
    if line.startswith("#") or not line.strip():
        continue
    text, expected = line.rstrip("\n").split("\t")
    cases.append((text, expected.split("|")))

env = dict(os.environ, SWIFT_DETERMINISTIC_HASHING="1")
out = subprocess.run([os.path.join(HERE, "work", "segcli"), "run"], input="\n".join(t for t, _ in cases) + "\n",
                     capture_output=True, text=True, env=env, check=True).stdout.split("\n")

failures = 0
for (text, expected), line in zip(cases, out):
    got = [part.split("\x1f")[0] for part in line.split("\x1e")]
    if got != expected:
        failures += 1
        print(f"want {' | '.join(expected)}\n got {' | '.join(got)}\n")
print(f"{len(cases) - failures}/{len(cases)} named cases hold")
sys.exit(1 if failures else 0)
