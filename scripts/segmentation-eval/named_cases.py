#!/usr/bin/env python3
"""Checks the named segmentation cases (KiokuTests/Fixtures/segmentation/named-cases.json) against the
shipped segmenter. The test suite checks the same file (NamedSegmentationCasesTests); this is the fast path.

  python3 named_cases.py         (expects work/segcli; build it with cli/build.sh)

Prints each case whose segmentation (or lemma, where the case names one) differs and exits non-zero if
any do. Takes seconds — run it before any segmentation change goes up, alongside the held2k / lyrics numbers.
"""
import json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
CASES = os.path.join(HERE, "..", "..", "KiokuTests", "Fixtures", "segmentation", "named-cases.json")
cases = [c for g in json.load(open(CASES, encoding="utf-8"))["groups"] for c in g["cases"]]

env = dict(os.environ, SWIFT_DETERMINISTIC_HASHING="1")
segcli = os.path.join(HERE, "work", "segcli")
run = os.environ["SEGCLI_RUN"].split() if "SEGCLI_RUN" in os.environ else [segcli, "run"]
out = subprocess.run(run, input="\n".join(c["text"] for c in cases) + "\n",
                     capture_output=True, text=True, env=env, check=True).stdout.split("\n")
# helpers prints "surface<TAB>lemma + helper…" (or "-"): the lemma is the preferred one, as the app shows it.
with_lemma = [c for c in cases if "lemma" in c]
helpers = subprocess.run([segcli, "helpers"], input="\n".join(c["text"] for c in with_lemma) + "\n",
                         capture_output=True, text=True, env=env, check=True).stdout.split("\n")
lemma_of = {line.split("\t")[0]: line.split("\t")[1].split(" + ")[0] for line in helpers if "\t" in line}

failures = 0
for case, line in zip(cases, out):
    got = [part.split("\x1f")[0] for part in line.split("\x1e")]
    if got != case["segments"]:
        failures += 1
        print(f"want {' | '.join(case['segments'])}\n got {' | '.join(got)}\n")
    elif "lemma" in case and lemma_of.get(case["text"]) != case["lemma"]:
        failures += 1
        print(f"{case['text']}: want lemma {case['lemma']}, got {lemma_of.get(case['text'])}\n")
print(f"{len(cases) - failures}/{len(cases)} named cases hold")
sys.exit(1 if failures else 0)
