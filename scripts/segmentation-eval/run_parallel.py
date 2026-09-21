#!/usr/bin/env python3
"""Runs `segcli run` over a sentence file on several cores and prints the output in input order.
  run_parallel.py work/data/held2k.txt > work/held2k.out        (env such as SPLIT_CLUSTERS / STRATEGY passes through)
Three workers by default (WORKERS=n to change): each is its own process with its own copy of the
dictionary in memory, and this is a 16 GB laptop someone is using — six workers made it unusable. All workers must share one configuration: segcli keeps its settings
in one UserDefaults domain, so never run two different configurations at the same time."""
import os, subprocess, sys
here = os.path.dirname(os.path.abspath(__file__))
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
if lines and lines[-1] == "": lines.pop()
workers = max(1, min(int(os.environ.get("WORKERS", "3")), len(lines)))
size = -(-len(lines) // workers)
chunks = [lines[i:i + size] for i in range(0, len(lines), size)]
procs = [subprocess.Popen([os.path.join(here, "work", "segcli"), "run"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, text=True, encoding="utf-8") for _ in chunks]
import threading
outs = [None] * len(chunks)
def feed(i):
    # communicate() per worker on its own thread, so every worker is fed and drained at once.
    outs[i] = procs[i].communicate("\n".join(chunks[i]) + "\n")[0]
threads = [threading.Thread(target=feed, args=(i,)) for i in range(len(chunks))]
for t in threads: t.start()
for t in threads: t.join()
for i, (chunk, out) in enumerate(zip(chunks, outs)):
    got = out.split("\n")
    if got and got[-1] == "": got.pop()
    if procs[i].returncode != 0 or len(got) != len(chunk):
        sys.exit(f"worker {i}: exit {procs[i].returncode}, {len(got)} lines for {len(chunk)} sentences")
    sys.stdout.write("\n".join(got) + "\n")
