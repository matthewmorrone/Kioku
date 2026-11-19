#!/usr/bin/env python3
"""Does adding the NDL bibliography tokens (ndl_tokens.py) to training help the per-kanji regression?
Two tests, both with embeddings + class one-hots (lr.py's 'both+classes'):
  1. the Tatoeba folds of cv.py: train on the other folds (plus, for the NDL models, every NDL token outside
     the held-out titles), score the held fold; compared with the Tatoeba-only regression and the control.
  2. NDL held-out titles (every 5th): train on all Tatoeba (plus the other NDL titles), score them.
NDL tokens enter at sample weight W (a sweep). A kanji with fewer than MIN_TRAIN tokens (Tatoeba + NDL for the NDL
models) falls back to the control, so tokens are scored identically across models.

  python3 lr_ndl.py <work dir> <vectors.npz> <ndl_tokens.pkl> [C] [W,W,...]"""
import collections, os, pickle, sys, warnings
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sklearn.linear_model import LogisticRegression
from common import base_scores, compare, fit, fold_ranges, load_tokens, meaning_ambiguous
from cv import DB, FOLDS, context_vectors
from lr import MIN_TRAIN, neighbour_vectors

warnings.filterwarnings('ignore')


def features(tokens, idf, vec_path):
    """(N x D) rows of embeddings (previous word, next word, boundary flags, bag) and class one-hots."""
    bag, _ = context_vectors({'tokens': tokens, 'idf': idf}, vec_path, 5)
    pn = neighbour_vectors(tokens, vec_path)
    vocab = [sorted({t['cls'][s] for t in tokens}) for s in range(2)]
    index = [{c: i for i, c in enumerate(v)} for v in vocab]
    onehot = np.zeros((len(tokens), len(vocab[0]) + len(vocab[1])), dtype=np.float32)
    for n, t in enumerate(tokens):
        onehot[n, index[0][t['cls'][0]]] = 1
        onehot[n, len(vocab[0]) + index[1][t['cls'][1]]] = 1
    return np.hstack([pn, bag, onehot])


def main(work, vec_path, ndl_path, c_value=10.0, weights=(1.0,)):
    """Runs both tests and prints the tables."""
    cache = load_tokens(os.path.join(work, 'tokens.pkl'))
    tat = cache['tokens']
    ndl = pickle.load(open(ndl_path, 'rb'))
    tokens = tat + ndl
    n_tat = len(tat)
    F = features(tokens, cache['idf'], vec_path)
    # Last column: 1 for an NDL token, 0 for Tatoeba. The "+flag" models use it, so the NDL tokens can teach the
    # shared weights while the prior stays Tatoeba's (a Tatoeba token to score always carries 0).
    F = np.hstack([F, (np.arange(len(tokens)) >= n_tat).astype(np.float32)[:, None]])
    ambiguous_kanji = meaning_ambiguous(DB, tat)
    ndl_held = [n_tat + i for i, t in enumerate(ndl) if (t['sid'] - 10 ** 9) % 5 == 0]
    ndl_train = [n_tat + i for i, t in enumerate(ndl) if (t['sid'] - 10 ** 9) % 5 != 0]
    ndl_by_kanji = collections.defaultdict(list)
    for n in ndl_train:
        ndl_by_kanji[tokens[n]['k']].append(n)
    tat_by_kanji = collections.defaultdict(list)
    for n, t in enumerate(tat):
        tat_by_kanji[t['k']].append(n)
    print(f'{n_tat} Tatoeba tokens, {len(ndl)} NDL tokens ({len(ndl_train)} train, {len(ndl_held)} held-out)')

    def run(train_tat, train_ndl, w, held, control_fn, flag=False):
        """{token: hit} for one model on `held` tokens grouped by kanji; falls back to control_fn(n) -> hit."""
        out = {}
        by_kanji = collections.defaultdict(list)
        for n in held:
            by_kanji[tokens[n]['k']].append(n)
        for k, ns in by_kanji.items():
            rows = train_tat(k) + (train_ndl(k) if w else [])
            labels = [tokens[i]['r'] for i in rows]
            weight = np.array([1.0 if i < n_tat else w for i in rows])
            if len(rows) < MIN_TRAIN or len(set(labels)) < 2:
                for n in ns:
                    out[n] = control_fn(n)
                continue
            cols = slice(None) if flag else slice(0, -1)
            clf = LogisticRegression(C=c_value, max_iter=200).fit(F[rows][:, cols], labels, sample_weight=weight)
            picks = clf.classes_[np.argmax(clf.predict_log_proba(F[ns][:, cols]), axis=1)]
            for n, pick in zip(ns, picks):
                out[n] = int(pick == tokens[n]['r'])
        return out

    models = ['tat only'] + [f'tat+ndl w={w}' for w in weights] + [f'tat+ndl+flag w={w}' for w in weights]
    hits = {name: {} for name in ['control'] + models}
    seen = {}
    for f, (lo, hi) in enumerate(fold_ranges(n_tat, FOLDS)):
        m = fit(tat[:lo] + tat[hi:])
        held = [n for n in range(lo, hi) if len(m['readings'][tat[n]['k']]) > 1]
        control = {}
        for n in held:
            parts = base_scores(m, tat[n])
            pick = max(parts, key=lambda x: parts[x][0] + parts[x][1])
            control[n] = int(pick == tat[n]['r'])
            seen[n] = m['occ'][(tat[n]['k'], tat[n]['r'])]
        hits['control'].update(control)
        train_tat = lambda k: [i for i in tat_by_kanji[k] if not lo <= i < hi]
        hits['tat only'].update(run(train_tat, lambda k: [], 0, held, control.get))
        for w in weights:
            hits[f'tat+ndl w={w}'].update(run(train_tat, lambda k: ndl_by_kanji[k], w, held, control.get))
            hits[f'tat+ndl+flag w={w}'].update(run(train_tat, lambda k: ndl_by_kanji[k], w, held, control.get, True))
        print(f'fold {f + 1}/{FOLDS} done', flush=True)
    order = sorted(hits['control'])
    table = {name: [h[n] for n in order] for name, h in hits.items()}
    meta = [(tat[n]['k'] in ambiguous_kanji, tat[n]['num_before'] or tat[n]['num_after']) for n in order]
    clean = [i for i, (_, num) in enumerate(meta) if not num]
    print('\n== TATOEBA folds, by how often the true reading was seen in Tatoeba training: right/total')
    for low, high in ((0, 5), (5, 20), (20, 100), (100, 10 ** 9)):
        subset = [i for i in clean if low <= seen[order[i]] < high]
        print(f'seen {low}-{high - 1 if high < 10 ** 9 else "+"}: {len(subset)} tokens  ' + '  '.join(f'{k} {sum(h[i] for i in subset)}' for k, h in table.items()))
    for title, subset in (('OVERALL', clean), ('MEANING-AMBIGUOUS', [i for i in clean if meta[i][0]])):
        print(f'\n== TATOEBA folds, {title}: model, right/total, accuracy, discordant vs control, sign-test p')
        for name, h in table.items():
            print(compare(name, h, table['control'], subset))
    pickle.dump(dict(index=order, hits=table), open(os.path.join(work, 'hits-lrndl-tatoeba.pkl'), 'wb'))

    # Test 2: NDL held-out titles, models trained on all of Tatoeba (plus the other NDL titles).
    m = fit(tat)
    ndl_control = {}
    for n in ndl_held:
        t = tokens[n]
        if len(m['readings'].get(t['k'], [])) < 2:
            continue
        parts = base_scores(m, t)
        ndl_control[n] = int(max(parts, key=lambda x: parts[x][0] + parts[x][1]) == t['r'])
    held = sorted(ndl_control)
    all_tat = lambda k: tat_by_kanji[k]
    ndl_hits = {'control (Tatoeba counts)': ndl_control, 'tat only': run(all_tat, lambda k: [], 0, held, ndl_control.get)}
    for w in weights:
        ndl_hits[f'tat+ndl w={w}'] = run(all_tat, lambda k: ndl_by_kanji[k], w, held, ndl_control.get)
        ndl_hits[f'tat+ndl+flag w={w}'] = run(all_tat, lambda k: ndl_by_kanji[k], w, held, ndl_control.get, True)
    ref = [ndl_control[n] for n in held]
    print(f'\n== NDL HELD-OUT titles ({len(held)} tokens): model, right/total, accuracy, discordant vs control, sign-test p')
    for name, h in ndl_hits.items():
        print(compare(name, [h[n] for n in held], ref))


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4]) if len(sys.argv) > 4 else 10.0,
         tuple(float(x) for x in sys.argv[5].split(',')) if len(sys.argv) > 5 else (1.0,))
