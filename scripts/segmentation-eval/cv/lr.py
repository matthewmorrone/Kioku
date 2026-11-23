#!/usr/bin/env python3
"""Does one learned model over embeddings subsume the class terms and the neighbour-word adjustment?
Per kanji, a multinomial logistic regression over its readings (the intercept is the prior) on:
  prevnext  the embedding of the word directly before and of the word directly after (unweighted, function
            words included) plus two BOUNDARY flags
  bag       the IDF-weighted mean embedding of the +-RADIUS words (cv.py's vote vector)
  both      all of the above
Same folds, tokens and sign test as cv.py. A kanji with fewer than MIN_TRAIN training tokens falls back to
the control's pick, so every model is scored on the same tokens.

  python3 lr.py <work dir> <vectors.npz> [C,C,...]   (default 3)
Feature sets fitted per C: 'classes' (one-hot previous and next grammar class), 'both' (embeddings), 'both+classes'."""
import collections, os, sys, warnings
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sklearn.linear_model import LogisticRegression
from common import base_scores, compare, fit, fold_ranges, load_tokens, meaning_ambiguous
from cv import DB, FOLDS, context_vectors

MIN_TRAIN = 20
warnings.filterwarnings('ignore')


def neighbour_vectors(tokens, vec_path):
    """(N x 602) features: unit embedding of the previous word, of the next word, then two BOUNDARY flags.
    A BOUNDARY neighbour (gap, edge, dropped number) or one without a vector is all zeros."""
    data = np.load(vec_path)
    row = {w: i for i, w in enumerate(data['words'])}
    vectors = data['vectors'].astype(np.float32)
    d = vectors.shape[1]
    out = np.zeros((len(tokens), 2 * d + 2), dtype=np.float32)
    for n, t in enumerate(tokens):
        near = {o: w for o, w in t['window'] if o in (-1, 1)}
        for s, o in enumerate((-1, 1)):
            if t['cls'][s] == 'BOUNDARY':
                out[n, 2 * d + s] = 1
            elif near.get(o) in row:
                out[n, s * d:(s + 1) * d] = vectors[row[near[o]]]
    return out


def main(work, vec_path, c_values=(3.0,)):
    """Runs the folds, fitting one regression per kanji per feature set, and prints the tables."""
    cache = load_tokens(os.path.join(work, 'tokens.pkl'))
    tokens = cache['tokens']
    ambiguous_kanji = meaning_ambiguous(DB, tokens)
    bag, _ = context_vectors(cache, vec_path, 5)
    pn = neighbour_vectors(tokens, vec_path)
    vocab = [sorted({t['cls'][s] for t in tokens}) for s in range(2)]
    index = [{c: i for i, c in enumerate(v)} for v in vocab]
    onehot = np.zeros((len(tokens), len(vocab[0]) + len(vocab[1])), dtype=np.float32)
    for n, t in enumerate(tokens):
        onehot[n, index[0][t['cls'][0]]] = 1
        onehot[n, len(vocab[0]) + index[1][t['cls'][1]]] = 1
    emb = np.hstack([pn, bag])
    features = {'classes': onehot, 'both': emb, 'both+classes': np.hstack([emb, onehot])}
    X = emb
    fallback = 0
    scored = 0
    by_kanji = collections.defaultdict(list)
    for n, t in enumerate(tokens):
        by_kanji[t['k']].append(n)
    hits = collections.defaultdict(dict)   # model -> token index -> 0/1
    seen = {}                              # token index -> training count of its true reading
    for f, (lo, hi) in enumerate(fold_ranges(len(tokens), FOLDS)):
        m = fit(tokens[:lo] + tokens[hi:])
        held = collections.defaultdict(list)
        for n in range(lo, hi):
            if len(m['readings'][tokens[n]['k']]) > 1:
                held[tokens[n]['k']].append(n)
        control = {}
        for n in (n for ns in held.values() for n in ns):
            t = tokens[n]
            parts = base_scores(m, t)
            control[n] = {x: parts[x][0] + parts[x][1] for x in parts}
            hits['control'][n] = int(max(control[n], key=control[n].get) == t['r'])
            seen[n] = m['occ'][(t['k'], t['r'])]
        for k, ns in held.items():
            train = [i for i in by_kanji[k] if not lo <= i < hi]
            labels = [tokens[i]['r'] for i in train]
            fitted = len(train) >= MIN_TRAIN and len(set(labels)) > 1
            scored += len(ns)
            if not fitted:
                fallback += len(ns)
            for c_value, (fname, F) in ((c, kv) for c in c_values for kv in features.items()):
                name = f'{fname} C={c_value}'
                if fitted:
                    clf = LogisticRegression(C=c_value, max_iter=200).fit(F[train], labels)
                    logp = clf.predict_log_proba(F[ns])
                for j, n in enumerate(ns):
                    t = tokens[n]
                    if not fitted:
                        hits[name][n] = hits['control'][n]
                        hits[name + ' + control'][n] = hits['control'][n]
                        continue
                    scores = dict(zip(clf.classes_, logp[j]))
                    hits[name][n] = int(max(scores, key=scores.get) == t['r'])
                    stacked = {x: control[n].get(x, -1e9) + scores.get(x, -1e9) for x in control[n]}
                    hits[name + ' + control'][n] = int(max(stacked, key=stacked.get) == t['r'])
        print(f'fold {f + 1}/{FOLDS} done', flush=True)
    print(f'{fallback} of {scored} ambiguous held tokens ({100 * fallback / scored:.1f}%) fall back to the control (kanji with < {MIN_TRAIN} training tokens)')
    counts = collections.Counter((t['k'], t['r']) for t in tokens)
    readings = collections.Counter()
    sizes = collections.Counter()
    for (k, r), n in counts.items():
        readings[k] += 1
        sizes[k] += n
    fitted_kanji = [k for k in readings if readings[k] > 1 and sizes[k] >= MIN_TRAIN]
    weights = sum(readings[k] * (X.shape[1] + 1) for k in fitted_kanji)
    print(f'final model: {len(fitted_kanji)} kanji, {weights} weights = {weights * 2 / 1e6:.1f} MB as float16 '
          f'(+ {len(np.load(vec_path)["words"])} word vectors x {X.shape[1] // 3 - 0} dims)')
    order = sorted(hits['control'])
    import pickle
    pickle.dump(dict(index=order, hits={name: [h[n] for n in order] for name, h in hits.items()}),
                open(os.path.join(work, f'hits-lr{os.environ.get("TAG", "")}.pkl'), 'wb'))
    table = {name: [h[n] for n in order] for name, h in hits.items()}
    meta = [(tokens[n]['k'] in ambiguous_kanji, tokens[n]['num_before'] or tokens[n]['num_after']) for n in order]
    clean = [i for i, (_, num) in enumerate(meta) if not num]
    print('\n== by how often the true reading was seen in training (no numeral gap): control vs each model, right/total')
    for low, high in ((0, 5), (5, 20), (20, 100), (100, 10 ** 9)):
        subset = [i for i in clean if low <= seen[order[i]] < high]
        print(f'seen {low}-{high - 1 if high < 10 ** 9 else "+"}: {len(subset)} tokens  ' + '  '.join(
            f'{name} {sum(h[i] for i in subset)}' for name, h in table.items() if '+' not in name))
    for title, subset in (('OVERALL (no numeral gap)', clean), ('MEANING-AMBIGUOUS (no numeral gap)', [i for i in clean if meta[i][0]]),
                          ('other ambiguous (no numeral gap)', [i for i in clean if not meta[i][0]]),
                          ('beside a numeral gap', [i for i, (_, num) in enumerate(meta) if num])):
        print(f'\n== {title} ): model, right/total, accuracy, discordant vs control, sign-test p')
        for name, h in table.items():
            print(compare(name, h, table['control'], subset))


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2], tuple(float(c) for c in sys.argv[3].split(',')) if len(sys.argv) > 3 else (3.0,))
