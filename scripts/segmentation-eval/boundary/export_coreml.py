#!/usr/bin/env python3
"""Exports a trained boundary model for the app: Kioku/Dictionary/Segmenter/SegmentBoundaryNet.mlpackage
(float32, any length) and SegmentBoundaryVocab.json (character → embedding index, unknown = 1).
  python3 boundary/export_coreml.py work/boundary-path[,work/boundary-relabel,…]   (several: P(cut) averaged)
BoundaryModel.swift feeds it exactly what model.gap_inputs builds for one sentence."""
import json, os, sys
import coremltools as ct
import numpy as np
import torch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from model import GAP_INPUTS, BoundaryModel  # noqa: E402

outdirs = sys.argv[1].split(",")
root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
dest = os.path.join(root, "Kioku", "Dictionary", "Segmenter")
metas = [json.load(open(os.path.join(d, "vocab.json"), encoding="utf-8")) for d in outdirs]
if not all(m["use_path"] for m in metas):
    sys.exit("BoundaryModel.swift always feeds the shipped path's cuts; export models trained with them")
# One character table for every model: each model's embedding rows are moved to the shared
# indices, and a character a model never saw gets that model's unknown row.
union = sorted(set().union(*(m["vocab"] for m in metas)))
vocab = {c: i + 2 for i, c in enumerate(union)}
models = []
for d, meta in zip(outdirs, metas):
    own = BoundaryModel(len(meta["vocab"]) + 2)
    own.load_state_dict(torch.load(os.path.join(d, "model.pt")))
    shared = BoundaryModel(len(vocab) + 2)
    state = own.state_dict()
    table = state["chars.weight"]
    rows = [table[0], table[1]] + [table[meta["vocab"][c]] if c in meta["vocab"] else table[1] for c in union]
    state["chars.weight"] = torch.stack(rows)
    shared.load_state_dict(state)
    shared.eval()
    models.append(shared)


class Exported(torch.nn.Module):
    # One sentence, no padding: the models' P(cut) per gap, averaged.
    def __init__(self, inner):
        super().__init__()
        self.inner = torch.nn.ModuleList(inner)

    def forward(self, chars, scripts, gaps):
        return torch.stack([torch.sigmoid(m(chars, scripts, gaps)) for m in self.inner]).mean(dim=0)


model = Exported(models).eval()
n = 12
example = (torch.randint(2, 50, (1, n)), torch.randint(0, 8, (1, n)), torch.rand(1, n - 1, GAP_INPUTS))
traced = torch.jit.trace(model, example)
length = ct.RangeDim(lower_bound=2, upper_bound=8192, default=n)
gaps = ct.RangeDim(lower_bound=1, upper_bound=8191, default=n - 1)
mlmodel = ct.convert(
    traced,
    inputs=[
        ct.TensorType(name="chars", shape=(1, length), dtype=np.int32),
        ct.TensorType(name="scripts", shape=(1, length), dtype=np.int32),
        ct.TensorType(name="gaps", shape=(1, gaps, GAP_INPUTS), dtype=np.float32),
    ],
    outputs=[ct.TensorType(name="cut")],
    compute_precision=ct.precision.FLOAT32,
    minimum_deployment_target=ct.target.iOS18,
)
mlmodel.short_description = "Kioku segmenter boundary model: P(cut) per gap between characters."
mlmodel.save(os.path.join(dest, "SegmentBoundaryNet.mlpackage"))
json.dump(vocab, open(os.path.join(dest, "SegmentBoundaryVocab.json"), "w", encoding="utf-8"), ensure_ascii=False, sort_keys=True)

# The converted model must agree with PyTorch, or the app scores differently from the eval.
check = (torch.randint(2, 50, (1, 30)), torch.randint(0, 8, (1, 30)), torch.rand(1, 29, GAP_INPUTS))
want = model(*check).detach().numpy()
got = mlmodel.predict({"chars": check[0].numpy().astype(np.int32), "scripts": check[1].numpy().astype(np.int32),
                       "gaps": check[2].numpy().astype(np.float32)})["cut"]
print("max |coreml - torch|:", float(np.abs(np.array(got).reshape(want.shape) - want).max()))
print("wrote", os.path.join(dest, "SegmentBoundaryNet.mlpackage"))
