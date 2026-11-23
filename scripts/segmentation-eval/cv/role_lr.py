#!/usr/bin/env python3
"""Does a learned, pooled grammatical-role model help the per-kanji embedding regression?
A reader first decides what the word is from its neighbours (a bound noun after の / a verb form, a suffix after a
name), then reads it accordingly. Here one multinomial regression, shared by every kanji, predicts the COARSE ROLE
of the true reading (suffix, noun, verb, adjective, adverb, function word) from the previous and next word's
embedding and grammar class. A candidate reading's term is log P(role | context) - log P(role), averaged over the
roles its JMdict entries carry, added to the per-kanji regression's log-probability times a weight.

  python3 role_lr.py <work dir with tokens.pkl> <vectors.npz> <dictionary.sqlite> [C]

Same folds, MIN_TRAIN fallback and sign test as role.py; the pooled model is refitted on each fold's training part."""
import collections, os, sys, warnings
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sklearn.linear_model import LogisticRegression
from common import base_scores, compare, fit, fold_ranges, load_tokens, meaning_ambiguous
from cv import FOLDS, context_vectors
from lr import MIN_TRAIN, neighbour_vectors
from role import reading_roles

warnings.filterwarnings('ignore')
WEIGHTS = (0.0, 0.25, 0.5, 1.0, 2.0)
COARSE = {'n-suf': 'suffix', 'suf': 'suffix', 'ctr': 'suffix', 'n': 'noun', 'v1': 'verb', 'v5': 'verb', 'vs-i': 'verb',
          'vk': 'verb', 'v-other': 'verb', 'adj-i': 'adj', 'adj-na': 'adj', 'adj-no': 'adj', 'adj-pn': 'adj',
          'adj-t': 'adj', 'adj-f': 'adj', 'adv': 'adv', 'adv-to': 'adv', 'prt': 'func', 'cop': 'func', 'aux-v': 'func',
          'aux-adj': 'func', 'aux': 'func', 'conj': 'func', 'exp': 'func', 'pn': 'func', 'int': 'func', 'num': 'func',
          'pref': 'noun', 'n-pref': 'noun'}


def coarse_roles(roles, kanji, reading):
    """The coarse roles of every JMdict entry written with this kanji run read this way."""
    return {COARSE[c] for c in roles.get((kanji, reading), set()) if c in COARSE}


def main(work, vec_path, db_path, c_value=10.0):
    """Runs the folds and prints accuracy per weight overall, on meaning-ambiguous kanji, on 様, after の."""
    cache = load_tokens(os.path.join(work, 'tokens.pkl'))
    tokens = cache['tokens']
    ambiguous = meaning_ambiguous(db_path, tokens)
    bag, _ = context_vectors(cache, vec_path, 5)
    X = np.hstack([neighbour_vectors(tokens, vec_path), bag])
    pn = X[:, :602]
    vocab = [sorted({t['cls'][s] for t in tokens}) for s in range(2)]
    index = [{c: i for i, c in enumerate(v)} for v in vocab]
    onehot = np.zeros((len(tokens), len(vocab[0]) + len(vocab[1])), dtype=np.float32)
    for n, t in enumerate(tokens):
        onehot[n, index[0][t['cls'][0]]] = 1
        onehot[n, len(vocab[0]) + index[1][t['cls'][1]]] = 1
    Z = np.hstack([pn, onehot])
    roles = reading_roles(db_path)
    labels = [(lambda c: next(iter(c)) if len(c) == 1 else None)(coarse_roles(roles, t['k'], t['r'])) for t in tokens]
    print(f'{sum(l is not None for l in labels)} of {len(tokens)} tokens have one coarse role: '
          + ', '.join(f'{k} {v}' for k, v in collections.Counter(l for l in labels if l).most_common()))
    by_kanji = collections.defaultdict(list)
    for n, t in enumerate(tokens):
        by_kanji[t['k']].append(n)
    hits = collections.defaultdict(dict)
    for f, (lo, hi) in enumerate(fold_ranges(len(tokens), FOLDS)):
        m = fit(tokens[:lo] + tokens[hi:])
        train_rows = [n for n in range(len(tokens)) if not lo <= n < hi and labels[n]]
        pooled = LogisticRegression(C=1.0, max_iter=100).fit(Z[train_rows], [labels[n] for n in train_rows])
        prior = collections.Counter(labels[n] for n in train_rows)
        log_prior = {r: np.log(prior[r] / len(train_rows)) for r in pooled.classes_}
        held = collections.defaultdict(list)
        for n in range(lo, hi):
            if len(m['readings'][tokens[n]['k']]) > 1:
                held[tokens[n]['k']].append(n)
        for k, ns in held.items():
            train = [i for i in by_kanji[k] if not lo <= i < hi]
            fitted = len(train) >= MIN_TRAIN and len({tokens[i]['r'] for i in train}) > 1
            if fitted:
                clf = LogisticRegression(C=c_value, max_iter=200).fit(X[train], [tokens[i]['r'] for i in train])
                logp = clf.predict_log_proba(X[ns])
            role_logp = pooled.predict_log_proba(Z[ns])
            for j, n in enumerate(ns):
                t = tokens[n]
                parts = base_scores(m, t)
                control = {x: parts[x][0] + parts[x][1] for x in parts}
                hits['control'][n] = int(max(control, key=control.get) == t['r'])

                def term(x):
                    """Mean over the reading's coarse roles of log P(role | context) - log P(role); 0 when unknown."""
                    rs = [r for r in coarse_roles(roles, t['k'], x) if r in log_prior]
                    return sum(role_logp[j][list(pooled.classes_).index(r)] - log_prior[r] for r in rs) / len(rs) if rs else 0.0
                for w in WEIGHTS:
                    base = dict(zip(clf.classes_, logp[j])) if fitted else control
                    scores = {x: base[x] + w * term(x) for x in base}
                    hits[f'lr+role {w}'][n] = int(max(scores, key=scores.get) == t['r'])
        print(f'fold {f + 1}/{FOLDS} done', flush=True)
    order = sorted(hits['control'])
    table = {name: [h[n] for n in order] for name, h in hits.items()}
    clean = [i for i, n in enumerate(order) if not (tokens[n]['num_before'] or tokens[n]['num_after'])]
    for title, subset in (('OVERALL (no numeral gap)', clean),
                          ('MEANING-AMBIGUOUS', [i for i in clean if tokens[order[i]]['k'] in ambiguous]),
                          ('様 only', [i for i in clean if tokens[order[i]]['k'] == '様']),
                          ('after の, any kanji', [i for i in clean if tokens[order[i]]['cls'][0] == 'w:の'])):
        print(f'\n== {title}: right/total, accuracy, discordant vs weight 0, p')
        for name, h in table.items():
            print(compare(name, h, table['lr+role 0.0'], subset))


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4]) if len(sys.argv) > 4 else 10.0)
