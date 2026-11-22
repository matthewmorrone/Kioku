#!/usr/bin/env python3
"""Does the segmenter's own cost of the kana-substituted text help the embedding model?

For a held-out token, each candidate reading replaces the kanji run in a +-12 character window and the segmenter
prices the cheapest path (segcli kanacost): の+よう+に is a cheap chunk, の+さま+に is not. The term is the
candidate's cost minus the cheapest candidate's, in nats, subtracted (times a weight) from the regression's
log-probability, so a reading that spells an unnatural chunk loses.

  python3 kana.py prepare <work> <vectors.npz> <dictionary.sqlite> <jpn_indices.csv> <sample size>
      runs the 10 folds, keeps each sampled token's regression log-probabilities, writes <work>/kana-in.jsonl
  segcli kanacost < <work>/kana-in.jsonl > <work>/kana-out.tsv      (DB=<dictionary.sqlite>)
  python3 kana.py analyze <work> <dictionary.sqlite>
      prints accuracy per weight, with the sign test against weight 0 (the regression alone)."""
import collections, json, os, pickle, random, sqlite3, sys, warnings
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pathlib import Path
from sklearn.linear_model import LogisticRegression
from common import compare, fit, fold_ranges, load_tokens, meaning_ambiguous
from cv import FOLDS, context_vectors
from lr import MIN_TRAIN, neighbour_vectors

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'scripts' / 'calibration'))
import usage_tables as u
from reading_model import training_tokens

warnings.filterwarnings('ignore')
WEIGHTS = (0.0, 0.1, 0.25, 0.5, 1.0)
CLIPS = (None, 4.0)


def spans_for(index_path, db_path, tokens):
    """The cached tokens' sentences and spans: the same gold records, in the same order, run through
    training_tokens again (the classes it reads are not needed here). Checks the sequence matches the cache."""
    db = sqlite3.connect(db_path)
    spellings = {(s, u.to_hiragana(r)) for s, r in db.execute('SELECT surface, reading FROM surface_readings')}
    irregular = {t for (t,) in db.execute("SELECT DISTINCT k.text FROM kanji k JOIN senses s ON s.entry_id = k.entry_id "
                                          "WHERE ',' || s.pos || ',' LIKE '%,vk,%' OR ',' || s.pos || ',' LIKE '%,adj-ix,%'")}
    sentences = {str(a): b for a, b in db.execute('SELECT DISTINCT ja_id, japanese FROM sentence_pairs')}
    gold = list(u.gold_sentences(open(index_path, encoding='utf-8-sig'), sentences))
    counted, _ = u.corpora(gold, REPO / 'scripts' / 'segmentation-eval' / 'data')
    counted = sorted(counted, key=lambda r: int(r['id']))
    again = list(training_tokens(counted, [''] * len(counted), irregular, spellings))
    if [(t['sid'], t['k'], t['r']) for t in again] != [(t['sid'], t['k'], t['r']) for t in tokens]:
        raise RuntimeError('regenerated tokens do not match the cache')
    text = {int(r['id']): r['s'] for r in counted}
    return [(text[t['sid']], t['span']) for t in again]


def prepare(work, vec_path, db_path, index_path, size):
    """Fits the folds, keeps the sampled tokens' log-probabilities and writes the segcli input."""
    cache = load_tokens(os.path.join(work, 'tokens.pkl'))
    tokens = cache['tokens']
    where = spans_for(index_path, db_path, tokens)
    bag, _ = context_vectors(cache, vec_path, 5)
    X = np.hstack([neighbour_vectors(tokens, vec_path), bag])
    by_kanji = collections.defaultdict(list)
    for n, t in enumerate(tokens):
        by_kanji[t['k']].append(n)
    rows = {}   # token index -> (candidates, log-probabilities)
    for f, (lo, hi) in enumerate(fold_ranges(len(tokens), FOLDS)):
        held = collections.defaultdict(list)
        for n in range(lo, hi):
            held[tokens[n]['k']].append(n)
        for k, ns in held.items():
            train = [i for i in by_kanji[k] if not lo <= i < hi]
            labels = [tokens[i]['r'] for i in train]
            if len(train) < MIN_TRAIN or len(set(labels)) < 2:
                continue
            clf = LogisticRegression(C=10.0, max_iter=200).fit(X[train], labels)
            for n, lp in zip(ns, clf.predict_log_proba(X[ns])):
                rows[n] = (list(clf.classes_), [float(x) for x in lp])
        print(f'fold {f + 1}/{FOLDS} done', flush=True)
    clean = [n for n in rows if not (tokens[n]['num_before'] or tokens[n]['num_after'])]
    rng = random.Random(7)
    chosen = set(rng.sample(clean, min(size, len(clean)))) | {n for n in clean if tokens[n]['k'] == '様'}
    order, lines = [], []
    for n in sorted(chosen):
        sentence, (a, b) = where[n]
        found = sentence[a:b].find(tokens[n]['k'])
        if found < 0:
            continue
        order.append(n)
        lines.append(json.dumps({'s': sentence, 'a': a + found, 'n': len(tokens[n]['k']), 'c': rows[n][0]}, ensure_ascii=False))
    open(os.path.join(work, 'kana-in.jsonl'), 'w').write('\n'.join(lines) + '\n')
    pickle.dump(dict(order=order, rows={n: rows[n] for n in order}), open(os.path.join(work, 'kana-state.pkl'), 'wb'))
    print(f'{len(order)} tokens written ({sum(1 for n in order if tokens[n]["k"] == "様")} of 様)')


def analyze(work, db_path):
    """Scores every weight and clip on the sampled tokens against the regression alone."""
    cache = load_tokens(os.path.join(work, 'tokens.pkl'))
    tokens = cache['tokens']
    state = pickle.load(open(os.path.join(work, 'kana-state.pkl'), 'rb'))
    costs = [line.rstrip('\n').split('\t') for line in open(os.path.join(work, 'kana-out.tsv'))][:len(state['order'])]
    ambiguous = meaning_ambiguous(db_path, tokens)
    hits = collections.defaultdict(list)
    for n, cost in zip(state['order'], costs):
        candidates, logp = state['rows'][n]
        values = [int(c) / 100 for c in cost]
        low = min(values)
        for clip in CLIPS:
            for w in WEIGHTS:
                if w == 0 and clip is not None:
                    continue
                scores = [lp - w * (min(v - low, clip) if clip else v - low) for lp, v in zip(logp, values)]
                hits[f'w={w} clip={clip}'].append(int(candidates[max(range(len(scores)), key=scores.__getitem__)] == tokens[n]['r']))
    base = hits['w=0.0 clip=None']
    idx = range(len(state['order']))
    for title, subset in (('SAMPLE', list(idx)),
                          ('MEANING-AMBIGUOUS', [i for i in idx if tokens[state['order'][i]]['k'] in ambiguous]),
                          ('様 only', [i for i in idx if tokens[state['order'][i]]['k'] == '様'])):
        print(f'\n== {title}: right/total, accuracy, discordant vs weight 0, p  ({len(subset)} tokens)')
        for name, h in hits.items():
            print(compare(name, h, base, subset))


if __name__ == '__main__':
    if sys.argv[1] == 'prepare':
        prepare(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], int(sys.argv[6]))
    else:
        analyze(sys.argv[2], sys.argv[3])
