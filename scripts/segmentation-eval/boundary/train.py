#!/usr/bin/env python3
"""Trains the boundary model: P(cut) at every gap between two characters, from the characters around
it and the lattice's evidence there (BoundaryFeatures.swift, dumped by `segcli features`).

  python3 boundary/train.py work/train.features work/boundary [--no-path-feature] [--epochs N] [--extra work/train-kana.features]

The first 2,000 lines of train.features (= train2k) are the validation set; the rest is fitted.
Never pass a held-out set (held2k, fresh, kana2k) here. Writes <outdir>/model.pt and vocab.json."""
import argparse, json, math, os, random, sys, time
import torch
from torch import nn

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from model import BoundaryModel, gap_inputs, load_features  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("features")
ap.add_argument("outdir")
ap.add_argument("--no-path-feature", action="store_true", help="hide the shipped path's cuts from the model")
ap.add_argument("--epochs", type=int, default=3)
ap.add_argument("--batch", type=int, default=256)
ap.add_argument("--seed", type=int, default=0)
ap.add_argument("--extra", action="append", default=[], help="more features files to fit on (e.g. kana copies); never a held-out set")
args = ap.parse_args()
random.seed(args.seed)
torch.manual_seed(args.seed)
os.makedirs(args.outdir, exist_ok=True)

rows = load_features(args.features)
val, fit = rows[:2000], rows[2000:]
for extra in args.extra:
    fit += load_features(extra)
counts = {}
for r in fit:
    for c in r["c"]:
        counts[c] = counts.get(c, 0) + 1
# Characters seen at least twice get their own embedding; the rest share the unknown slot (index 1; 0 pads).
vocab = {c: i + 2 for i, c in enumerate(sorted(c for c, k in counts.items() if k >= 2))}
use_path = not args.no_path_feature
json.dump({"vocab": vocab, "use_path": use_path}, open(os.path.join(args.outdir, "vocab.json"), "w"), ensure_ascii=False)
print(f"fit {len(fit)} val {len(val)} vocab {len(vocab)} path-feature {use_path}", flush=True)

model = BoundaryModel(len(vocab) + 2)
print(f"parameters {sum(p.numel() for p in model.parameters())}", flush=True)
opt = torch.optim.AdamW(model.parameters(), lr=4e-3, weight_decay=1e-4)
loss_fn = nn.BCEWithLogitsLoss(reduction="sum")


def encoded_batches(data, size):
    # Length-sorted buckets so padding stays small, encoded to tensors once (encoding is the slow part).
    order = sorted(range(len(data)), key=lambda i: len(data[i]["c"]))
    return [gap_inputs([data[i] for i in order[j:j + size]], vocab, use_path) for j in range(0, len(order), size)]


val_batches = encoded_batches(val, 256)
fit_batches = encoded_batches(fit, args.batch)
print(f"encoded {len(fit_batches)} batches", flush=True)


def evaluate(data):
    # Gap accuracy of the model and of the shipped path, on gold-labelled gaps only.
    model.eval()
    right = path_right = total = 0
    loss = 0.0
    with torch.no_grad():
        for chars, scripts, gaps, labels, path in data:
            logits = model(chars, scripts, gaps)
            mask = labels >= 0
            loss += loss_fn(logits[mask], labels[mask].float()).item()
            right += ((logits[mask] > 0).long() == labels[mask]).sum().item()
            path_right += (path[mask] == labels[mask]).sum().item()
            total += mask.sum().item()
    model.train()
    return loss / total, right / total, path_right / total


started = time.time()
for epoch in range(args.epochs):
    seen = 0
    random.shuffle(fit_batches)
    for chars, scripts, gaps, labels, path in fit_batches:
        logits = model(chars, scripts, gaps)
        mask = labels >= 0
        loss = loss_fn(logits[mask], labels[mask].float()) / max(1, mask.sum().item())
        opt.zero_grad()
        loss.backward()
        opt.step()
        seen += 1
    for group in opt.param_groups:
        group["lr"] *= 0.6
    vloss, acc, path_acc = evaluate(val_batches)
    print(f"epoch {epoch + 1} ({time.time() - started:.0f} s): val loss {vloss:.4f}  gap accuracy {acc * 100:.2f}%  (shipped path {path_acc * 100:.2f}%)", flush=True)
    # Saved every epoch, so a run stopped early still leaves its last finished epoch.
    torch.save(model.state_dict(), os.path.join(args.outdir, "model.pt"))
