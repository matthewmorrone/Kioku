#!/usr/bin/env python3
"""Is a measured gain real or noise? For chosen model pairs, from the per-token results cv.py and lr.py save:
  folds     in how many of the 10 contiguous folds A beats B, and the per-fold accuracy deltas
  bootstrap 95% interval of the accuracy delta from resampling blocks of BLOCK consecutive sentence ids
            (tokens of a sentence and near-duplicate neighbours stay together, unlike the sign test's
            independent tokens); the share of resamples where A does not beat B
Tokens beside a numeral Tatoeba's index dropped are left out, as in the headline rows.

  python confirm.py <work dir>"""
import os, pickle, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import fold_ranges, load_tokens, meaning_ambiguous
from cv import DB, FOLDS

BLOCK = 100
RESAMPLES = 4000


def series(dump, name, n_tokens):
    """(token index array, 0/1 hits) of one model from a dump."""
    return np.array(dump['index']), np.array(dump['hits'][name])


def compare(label, a, b, tokens, sid, fold, mask):
    """Prints delta, per-fold wins and the block-bootstrap interval for hits a against hits b on mask."""
    idx_a, ha = a
    idx_b, hb = b
    assert (idx_a == idx_b).all()
    keep = mask[idx_a]
    idx, delta = idx_a[keep], (ha - hb)[keep]
    folds = fold[idx]
    per_fold = [delta[folds == f].mean() * 100 for f in range(FOLDS) if (folds == f).any()]
    blocks = sid[idx] // BLOCK
    _, inverse = np.unique(blocks, return_inverse=True)
    sums = np.bincount(inverse, weights=delta)
    counts = np.bincount(inverse)
    rng = np.random.default_rng(1)
    picks = rng.integers(0, len(sums), size=(RESAMPLES, len(sums)))
    boot = sums[picks].sum(axis=1) / counts[picks].sum(axis=1) * 100
    lo, hi = np.percentile(boot, [2.5, 97.5])
    print(f'{label:46} delta {delta.mean() * 100:+.2f} pts  95% CI [{lo:+.2f}, {hi:+.2f}]  '
          f'folds better {sum(d > 0 for d in per_fold)}/{len(per_fold)} (worst {min(per_fold):+.2f})  '
          f'resamples not better {np.mean(boot <= 0) * 100:.2f}%')


def main(work):
    """Runs every comparison for the whole and the meaning-ambiguous subset."""
    cache = load_tokens(os.path.join(work, 'tokens.pkl'))
    tokens = cache['tokens']
    sid = np.array([t['sid'] for t in tokens])
    fold = np.zeros(len(tokens), dtype=int)
    for f, (lo, hi) in enumerate(fold_ranges(len(tokens), FOLDS)):
        fold[lo:hi] = f
    clean = np.array([not (t['num_before'] or t['num_after']) for t in tokens])
    ambiguous = meaning_ambiguous(DB, tokens)
    meaning = np.array([t['k'] in ambiguous for t in tokens])
    dumps = {name: pickle.load(open(os.path.join(work, f'hits-{name}.pkl'), 'rb')) for name in ('cv', 'lrreal', 'lrrand')
             if os.path.exists(os.path.join(work, f'hits-{name}.pkl'))}
    cv, real, rand = dumps.get('cv'), dumps.get('lrreal'), dumps.get('lrrand')
    pairs = []
    if cv:
        for lam in (20, 40):
            pairs.append((f'control + cosine vote lam{lam}  vs control', series(cv, f'+words +emb mu0 lam{lam}', 0), series(cv, '+words (control)', 0)))
    if real:
        control = series(real, 'control', 0)
        for name in ('both C=10.0', 'both+classes C=10.0', 'classes C=10.0'):
            pairs.append((f'{name}  vs control', series(real, name, 0), control))
        pairs.append(('both+classes  vs  both', series(real, 'both+classes C=10.0', 0), series(real, 'both C=10.0', 0)))
    if real and rand:
        pairs.append(('REAL vectors  vs  RANDOM vectors (both)', series(real, 'both C=10.0', 0), series(rand, 'both C=10.0', 0)))
        pairs.append(('RANDOM vectors (both)  vs control', series(rand, 'both C=10.0', 0), series(rand, 'control', 0)))
    for title, mask in (('OVERALL (no numeral gap)', clean), ('MEANING-AMBIGUOUS (no numeral gap)', clean & meaning)):
        print(f'\n== {title}: A vs B, accuracy delta A-B, cluster-bootstrap CI, folds A>B')
        for label, a, b in pairs:
            compare(label, a, b, tokens, sid, fold, mask)


if __name__ == '__main__':
    main(sys.argv[1])
