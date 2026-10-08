#!/usr/bin/env python3
"""Writes the boundary model's P(cut) per gap for a features file — one JSON array per sentence line,
the input `segcli rescore` reads.  python3 boundary/predict.py work/boundary work/held2k.features > work/held2k.probs"""
import json, os, sys
import torch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from model import BoundaryModel, gap_inputs, load_features  # noqa: E402

outdir, features = sys.argv[1], sys.argv[2]
meta = json.load(open(os.path.join(outdir, "vocab.json"), encoding="utf-8"))
vocab, use_path = meta["vocab"], meta["use_path"]
model = BoundaryModel(len(vocab) + 2)
model.load_state_dict(torch.load(os.path.join(outdir, "model.pt")))
model.eval()
rows = load_features(features)
with torch.no_grad():
    for i in range(0, len(rows), 256):
        chunk = rows[i:i + 256]
        chars, scripts, gaps, _, _ = gap_inputs(chunk, vocab, use_path)
        p = torch.sigmoid(model(chars, scripts, gaps))
        for b, r in enumerate(chunk):
            n = len(r["c"])
            print(json.dumps([round(v, 5) for v in p[b, :max(0, n - 1)].tolist()]))
