#!/usr/bin/env python3
"""Exports a trained boundary model for the app: Kioku/Dictionary/Segmenter/SegmentBoundaryNet.mlpackage
(float32, any length) and SegmentBoundaryVocab.json (character → embedding index, unknown = 1).
  python3 boundary/export_coreml.py work/boundary-path
BoundaryModel.swift feeds it exactly what model.gap_inputs builds for one sentence."""
import json, os, sys
import coremltools as ct
import numpy as np
import torch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from model import GAP_INPUTS, BoundaryModel  # noqa: E402

outdir = sys.argv[1]
root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
dest = os.path.join(root, "Kioku", "Dictionary", "Segmenter")
meta = json.load(open(os.path.join(outdir, "vocab.json"), encoding="utf-8"))
if not meta["use_path"]:
    sys.exit("BoundaryModel.swift always feeds the shipped path's cuts; export a model trained with them")
model = BoundaryModel(len(meta["vocab"]) + 2)
model.load_state_dict(torch.load(os.path.join(outdir, "model.pt")))
model.eval()


class Exported(torch.nn.Module):
    # One sentence, no padding: P(cut) per gap instead of logits.
    def __init__(self, inner):
        super().__init__()
        self.inner = inner

    def forward(self, chars, scripts, gaps):
        return torch.sigmoid(self.inner(chars, scripts, gaps))


n = 12
example = (torch.randint(2, 50, (1, n)), torch.randint(0, 8, (1, n)), torch.rand(1, n - 1, GAP_INPUTS))
traced = torch.jit.trace(Exported(model), example)
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
json.dump(meta["vocab"], open(os.path.join(dest, "SegmentBoundaryVocab.json"), "w", encoding="utf-8"), ensure_ascii=False, sort_keys=True)

# The converted model must agree with PyTorch, or the app scores differently from the eval.
check = (torch.randint(2, 50, (1, 30)), torch.randint(0, 8, (1, 30)), torch.rand(1, 29, GAP_INPUTS))
want = torch.sigmoid(model(*check)).detach().numpy()
got = mlmodel.predict({"chars": check[0].numpy().astype(np.int32), "scripts": check[1].numpy().astype(np.int32),
                       "gaps": check[2].numpy().astype(np.float32)})["cut"]
print("max |coreml - torch|:", float(np.abs(np.array(got).reshape(want.shape) - want).max()))
print("wrote", os.path.join(dest, "SegmentBoundaryNet.mlpackage"))
