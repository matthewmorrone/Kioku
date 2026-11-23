#!/usr/bin/env python3
"""Do Tatoeba's kana-written tokens (様に written ように, reading_model.kana_token) help the per-kanji regression?
Each is a real sentence context labelled with a reading of a kanji the app scores, so they add training data
for kanji written in kanji. Held-out tokens are always kanji-written Tatoeba tokens from the cv.py folds; kana
tokens from the held-out sentences never train. Models, per kanji (a kanji with fewer than MIN_TRAIN training
tokens falls back to the control, so every model is scored on the same tokens):
  tat only         the shipped fit
  tat+kana         kana tokens join at sample weight W
  tat+kana+flag    the same with a source column, so the shared weights learn from their contexts while the
                   intercept (the prior) stays the kanji-written tokens'; the app scores with the column at 0

  python3 lr_kana.py <work dir with tokens.pkl from tokens.py> <vectors.npz> [C] [W,W,...]"""
import collections, os, sys, warnings
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sklearn.linear_model import LogisticRegression
from common import base_scores, compare, fit, fold_ranges, load_tokens, meaning_ambiguous
from cv import DB, FOLDS, context_vectors
from lr import MIN_TRAIN, neighbour_vectors

warnings.filterwarnings('ignore')


def main(work, vec_path, c_value=10.0, weights=(1.0,)):
    """Runs the folds and prints accuracy overall, on meaning-ambiguous kanji and on 様, with sign tests."""
    cache = load_tokens(os.path.join(work, 'tokens.pkl'))
    tat = cache['tokens']
    known = {(t['k'], t['r']) for t in tat}
    # A bare-kanji headword read from a longer kana surface (様 / ような) yields a wrong run; keep only readings
    # the kanji-written data shows for that kanji.
    kana = [t for t in cache['kana'] if (t['k'], t['r']) in known]
    tokens = tat + kana
    n_tat = len(tat)
    bag, _ = context_vectors({'tokens': tokens, 'idf': cache['idf']}, vec_path, 5)
    flag = (np.arange(len(tokens)) >= n_tat).astype(np.float32)[:, None]
    F = np.hstack([neighbour_vectors(tokens, vec_path), bag, flag])
    ambiguous = meaning_ambiguous(DB, tat)
    by_kanji = collections.defaultdict(list)
    for n, t in enumerate(tat):
        by_kanji[t['k']].append(n)
    kana_by_kanji = collections.defaultdict(list)
    for n in range(n_tat, len(tokens)):
        kana_by_kanji[tokens[n]['k']].append(n)
    held_kana = os.environ.get('HELD') == 'kana'   # score kana-written tokens (flag 0) instead: do kana contexts transfer?
    print(f'{n_tat} kanji-written tokens, {len(kana)} kana-written ({len({t["k"] for t in kana})} kanji)')
    models = ['tat only'] + [f'tat+kana w={w}' for w in weights] + [f'tat+kana+flag w={w}' for w in weights]
    hits = {name: {} for name in ['control'] + models}
    for f, (lo, hi) in enumerate(fold_ranges(n_tat, FOLDS)):
        first, last = tat[lo]['sid'], tat[hi - 1]['sid']
        m = fit(tat[:lo] + tat[hi:])
        held = collections.defaultdict(list)
        for n in range(lo, hi):
            if len(m['readings'][tat[n]['k']]) > 1:
                held[tat[n]['k']].append(n)
        if held_kana:
            held = collections.defaultdict(list)
            for n in range(n_tat, len(tokens)):
                if first <= tokens[n]['sid'] <= last and len(m['readings'][tokens[n]['k']]) > 1:
                    held[tokens[n]['k']].append(n)
        for k, ns in held.items():
            train = [i for i in by_kanji[k] if not lo <= i < hi]
            extra = [i for i in kana_by_kanji[k] if not first <= tokens[i]['sid'] <= last]
            controls = {}
            for n in ns:
                if held_kana:
                    controls[n] = 0
                else:
                    parts = base_scores(m, tat[n])
                    controls[n] = int(max(parts, key=lambda x: parts[x][0] + parts[x][1]) == tat[n]['r'])
                hits['control'][n] = controls[n]
            for name in models:
                w = 0.0 if name == 'tat only' else float(name.split('w=')[1])
                rows = train + (extra if w else [])
                labels = [tokens[i]['r'] for i in rows]
                if len(rows) < MIN_TRAIN or len(set(labels)) < 2:
                    for n in ns:
                        hits[name][n] = controls[n]
                    continue
                cols = slice(None) if 'flag' in name else slice(0, -1)
                weight = np.array([1.0 if i < n_tat else w for i in rows])
                clf = LogisticRegression(C=c_value, max_iter=200).fit(F[rows][:, cols], labels, sample_weight=weight)
                test = F[ns][:, cols].copy()
                if held_kana and 'flag' in name:
                    test[:, -1] = 0
                picks = clf.classes_[np.argmax(clf.predict_log_proba(test), axis=1)]
                for n, pick in zip(ns, picks):
                    hits[name][n] = int(pick == tokens[n]['r'])
        print(f'fold {f + 1}/{FOLDS} done', flush=True)
    order = sorted(hits['control'])
    table = {name: [h[n] for n in order] for name, h in hits.items()}
    clean = [i for i, n in enumerate(order) if not (tokens[n]['num_before'] or tokens[n]['num_after'])]
    for title, subset in (('OVERALL', clean),
                          ('MEANING-AMBIGUOUS', [i for i in clean if tokens[order[i]]['k'] in ambiguous]),
                          ('様 only', [i for i in clean if tokens[order[i]]['k'] == '様']),
                          ('kanji with kana tokens', [i for i in clean if tokens[order[i]]['k'] in kana_by_kanji])):
        print(f'\n== {title}: model, right/total, accuracy, discordant vs tat only, sign-test p')
        for name, h in table.items():
            print(compare(name, h, table['tat only'], subset))


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2], float(sys.argv[3]) if len(sys.argv) > 3 else 10.0,
         tuple(float(x) for x in sys.argv[4].split(',')) if len(sys.argv) > 4 else (1.0,))
