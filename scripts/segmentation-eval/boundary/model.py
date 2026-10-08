"""The boundary model and its input encoding, shared by train.py, predict.py and the CoreML export.

Per character: an embedding of the character and of its script class (BoundaryFeatures.scriptClass).
A stack of dilated 1-D convolutions reads the characters around each position; each gap's logit comes
from the two characters beside it plus that gap's lattice features (BoundaryFeatures.gapFeatures)."""
import json, math
import torch
from torch import nn

SCRIPT_CLASSES = 8           # BoundaryFeatures.scriptClass returns 0..<8; 8 pads
GAP_INPUTS = 15              # encode_gap's width


def load_features(path):
    # One JSON object per line, as `segcli features` prints them.
    with open(path, encoding="utf-8") as f:
        return [json.loads(line) for line in f if line.strip()]


def encode_gap(f, cut, use_path):
    # Lattice evidence at one gap, scaled for the network: edge counts as log(1 + n), node costs in
    # tens of nats with a has-none flag, then the shipped path's cut (0 when the model doesn't see it).
    out = [math.log1p(v) for v in f[:10]]
    for cost in (f[10], f[11]):
        out += [0.0, 1.0] if cost < 0 else [cost / 1000.0, 0.0]
    out.append(float(cut) if use_path else 0.0)
    return out


def gap_inputs(rows, vocab, use_path):
    # Pads a batch of feature rows into tensors: chars/scripts [B, L], gaps [B, L-1, GAP_INPUTS],
    # labels [B, L-1] (-1 = no gold label or padding), path [B, L-1].
    width = max(len(r["c"]) for r in rows)
    width = max(width, 2)
    chars = torch.zeros(len(rows), width, dtype=torch.long)
    scripts = torch.full((len(rows), width), SCRIPT_CLASSES, dtype=torch.long)
    gaps = torch.zeros(len(rows), width - 1, GAP_INPUTS)
    labels = torch.full((len(rows), width - 1), -1, dtype=torch.long)
    path = torch.zeros(len(rows), width - 1, dtype=torch.long)
    for b, r in enumerate(rows):
        n = len(r["c"])
        chars[b, :n] = torch.tensor([vocab.get(c, 1) for c in r["c"]])
        scripts[b, :n] = torch.tensor(r["k"])
        if n > 1:
            gaps[b, :n - 1] = torch.tensor([encode_gap(f, cut, use_path) for f, cut in zip(r["f"], r["b"])])
            labels[b, :n - 1] = torch.tensor(r["y"])
            path[b, :n - 1] = torch.tensor(r["b"])
    return chars, scripts, gaps, labels, path


class BoundaryModel(nn.Module):
    def __init__(self, vocab_size, char_dim=48, script_dim=8, hidden=96, dilations=(1, 2, 4)):
        super().__init__()
        self.chars = nn.Embedding(vocab_size, char_dim, padding_idx=0)
        self.scripts = nn.Embedding(SCRIPT_CLASSES + 1, script_dim, padding_idx=SCRIPT_CLASSES)
        self.inp = nn.Conv1d(char_dim + script_dim, hidden, 1)
        self.convs = nn.ModuleList(nn.Conv1d(hidden, hidden, 5, padding=2 * d, dilation=d) for d in dilations)
        self.gap = nn.Linear(GAP_INPUTS, hidden)
        self.out = nn.Sequential(nn.Linear(3 * hidden, hidden), nn.ReLU(), nn.Linear(hidden, 1))

    def forward(self, chars, scripts, gaps):
        # Padding is zeroed after every layer, so a padded batch computes exactly what one unpadded
        # sentence does (the app runs one sentence at a time).
        mask = (scripts != SCRIPT_CLASSES).unsqueeze(1).float()
        x = torch.cat([self.chars(chars), self.scripts(scripts)], dim=-1).transpose(1, 2)
        h = torch.relu(self.inp(x)) * mask
        for conv in self.convs:
            h = (h + torch.relu(conv(h))) * mask
        left, right = h[:, :, :-1].transpose(1, 2), h[:, :, 1:].transpose(1, 2)
        g = torch.relu(self.gap(gaps))
        return self.out(torch.cat([left, right, g], dim=-1)).squeeze(-1)
