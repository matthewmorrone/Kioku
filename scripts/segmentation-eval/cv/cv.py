#!/usr/bin/env python3
"""Cross-validated reading choice on the counted Tatoeba corpus: gold segmentation, no Apple vote, no
phrase table. The counted gold readings are cut into FOLDS contiguous blocks (by sentence id, so a
sentence's tokens and its near-duplicate neighbours stay in one fold); each block is scored with counts
from the others. Every model is scored on the same tokens and compared with the control (the app's
class terms plus neighbour-word adjustment) by discordant tokens and an exact sign test.

With a vectors file (vectors.py), it adds the embedding vote: for each (kanji, reading) a centroid of the
IDF-weighted mean embedding of the +-RADIUS words around every training occurrence; a candidate gains
LAMBDA * cosine(the token's own context, the candidate's centroid). A centroid can be shrunk toward the
kanji's all-reading centroid by MU pseudo-occurrences.

  python3 cv.py <work dir> [vectors.npz] [radius]

Rows are reported overall, for kanji whose common readings belong to different JMdict entries
(meaning-ambiguous) and for the rest. Tokens with a numeral dropped by Tatoeba's index right before or
after them (三人 -> BOUNDARY [人]) are left out of the headline rows and shown in a separate row."""
import collections, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import (base_scores, compare, fit, fold_ranges, load_tokens, meaning_ambiguous)

FOLDS = 10
LAMBDAS = (10, 20, 40)
PRIOR_LAMBDAS = (10, 20, 40, 80, 160)
MUS = (0,)
DB = os.environ.get('DB', '/Users/matthewmorrone/Projects/Kioku/Resources/dictionary.sqlite')


def context_vectors(cache, vec_path, radius):
    """(N x D unit context vectors, N booleans: any window word had a vector). A token's vector is the IDF-
    weighted mean of the unit embeddings of the lemmas within `radius` tokens of it."""
    data = np.load(vec_path)
    row = {w: i for i, w in enumerate(data['words'])}
    vectors = data['vectors'].astype(np.float32)
    idf = cache['idf']
    out = np.zeros((len(cache['tokens']), vectors.shape[1]), dtype=np.float32)
    for n, t in enumerate(cache['tokens']):
        acc, weight = np.zeros(vectors.shape[1], dtype=np.float32), 0.0
        for offset, w in t['window']:
            if abs(offset) <= radius and w in row:
                wt = idf.get(w, 1.0)
                acc += wt * vectors[row[w]]
                weight += wt
        norm = np.linalg.norm(acc)
        if norm > 0:
            out[n] = acc / norm
    return out, np.linalg.norm(out, axis=1) > 0


def centroids(tokens, ctx, has, lo, hi, groups, kanji_of):
    """Normalised centroid matrices per MU for the training part (everything outside [lo, hi)): one row per
    (kanji, reading) group, shrunk toward its kanji's all-reading mean by MU pseudo-occurrences."""
    train = np.ones(len(tokens), dtype=bool)
    train[lo:hi] = False
    train &= has
    ids = np.array([groups[(t['k'], t['r'])] for t in tokens])
    kids = np.array([kanji_of[groups[(t['k'], t['r'])]] for t in tokens])
    S = np.zeros((len(groups), ctx.shape[1]), dtype=np.float32)
    n = np.zeros(len(groups), dtype=np.float32)
    np.add.at(S, ids[train], ctx[train])
    np.add.at(n, ids[train], 1)
    K = np.zeros((int(kids.max()) + 1, ctx.shape[1]), dtype=np.float32)
    kn = np.zeros(K.shape[0], dtype=np.float32)
    np.add.at(K, kids[train], ctx[train])
    np.add.at(kn, kids[train], 1)
    mats = {}
    of_group = np.array(kanji_of)
    for mu in MUS:
        kmean = K[of_group] / np.maximum(kn[of_group], 1)[:, None]
        C = (S + mu * kmean) / (n + mu)[:, None] if mu else S / np.maximum(n, 1)[:, None]
        norm = np.linalg.norm(C, axis=1, keepdims=True)
        mats[mu] = C / np.where(norm > 0, norm, 1)
    return mats


def main(work, vec_path=None, radius=5):
    """Runs the folds and prints the results tables."""
    cache = load_tokens(os.path.join(work, 'tokens.pkl'))
    tokens = cache['tokens']
    print(f'{len(tokens)} counted readings from {cache["sentences"]} sentences')
    ambiguous_kanji = meaning_ambiguous(DB, tokens)
    print(f'{len(ambiguous_kanji)} meaning-ambiguous kanji runs')
    groups = {}
    for t in tokens:
        groups.setdefault((t['k'], t['r']), len(groups))
    kanji_ids = {}
    kanji_of = [0] * len(groups)
    for (k, r), g in groups.items():
        kanji_of[g] = kanji_ids.setdefault(k, len(kanji_ids))
    ctx = has = None
    if vec_path:
        ctx, has = context_vectors(cache, vec_path, radius)
        print(f'window vectors: {int(has.sum())} of {len(tokens)} tokens have at least one embedded word within +-{radius}')
    # A token is a near-duplicate when the same kanji, reading and window of lemmas occurs in another fold.
    folds = fold_ranges(len(tokens), FOLDS)
    fold_of = {n: f for f, (lo, hi) in enumerate(folds) for n in range(lo, hi)}
    seen_in = collections.defaultdict(set)
    for n, t in enumerate(tokens):
        seen_in[(t['k'], t['r'], tuple(w for _, w in t['window']))].add(fold_of[n])
    hits = collections.defaultdict(list)
    meta = []
    scored_index = []
    for f, (lo, hi) in enumerate(folds):
        m = fit(tokens[:lo] + tokens[hi:])
        mats = centroids(tokens, ctx, has, lo, hi, groups, kanji_of) if vec_path else None
        done = 0
        for n in range(lo, hi):
            t = tokens[n]
            options = m['readings'][t['k']]
            if len(options) < 2:
                continue
            parts = base_scores(m, t)
            picks = {'prior only': max(options, key=lambda x: parts[x][2]),
                     'classes (shipped)': max(options, key=lambda x: parts[x][0]),
                     '+words (control)': max(options, key=lambda x: parts[x][0] + parts[x][1])}
            if vec_path:
                for mu in MUS:
                    cos = {x: float(mats[mu][groups[(t['k'], x)]] @ ctx[n]) if (t['k'], x) in groups else 0.0 for x in options}
                    picks[f'embedding only mu{mu}'] = max(options, key=lambda x: cos[x])
                    for lam in PRIOR_LAMBDAS:
                        picks[f'REPLACE prior +emb lam{lam}'] = max(options, key=lambda x: parts[x][2] + lam * cos[x])
                    for lam in LAMBDAS:
                        picks[f'classes +emb lam{lam}'] = max(options, key=lambda x: parts[x][0] + lam * cos[x])
                        picks[f'+words +emb mu{mu} lam{lam}'] = max(options, key=lambda x: parts[x][0] + parts[x][1] + lam * cos[x])
            for name, x in picks.items():
                hits[name].append(int(x == t['r']))
            scored_index.append(n)
            meta.append((t['k'] in ambiguous_kanji, t['num_before'] or t['num_after'],
                         len(seen_in[(t['k'], t['r'], tuple(w for _, w in t['window']))] - {f}) > 0))
            done += 1
        print(f'fold {f + 1}/{FOLDS}: {done} ambiguous tokens', flush=True)
    import pickle
    pickle.dump(dict(index=scored_index, hits=dict(hits)), open(os.path.join(work, 'hits-cv.pkl'), 'wb'))
    control = hits['+words (control)']
    clean = [i for i, (m_, num, dup) in enumerate(meta) if not num]
    clean_meaning = [i for i in clean if meta[i][0]]
    clean_other = [i for i in clean if not meta[i][0]]
    numeral = [i for i, (m_, num, dup) in enumerate(meta) if num]
    print(f'\nscored {len(meta)} ambiguous tokens: {len(clean)} without a numeral gap '
          f'({len(clean_meaning)} meaning-ambiguous), {len(numeral)} beside one')
    unique = [i for i in clean if not meta[i][2]]
    unique_meaning = [i for i in unique if meta[i][0]]
    print(f'{len(clean) - len(unique)} of the clean tokens have an identical kanji+reading+context in another fold')
    for title, subset in (('no near-duplicate context elsewhere, overall', unique),
                          ('no near-duplicate context elsewhere, MEANING-AMBIGUOUS', unique_meaning),('OVERALL (no numeral gap)', clean), ('MEANING-AMBIGUOUS kanji (no numeral gap)', clean_meaning),
                          ('other ambiguous kanji (no numeral gap)', clean_other), ('tokens beside a numeral gap', numeral)):
        print(f'\n== {title}: model, right/total, accuracy, discordant vs control (+words), sign-test p')
        for name, h in hits.items():
            print(compare(name, h, control, subset))


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None, int(sys.argv[3]) if len(sys.argv) > 3 else 5)
