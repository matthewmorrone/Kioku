#!/usr/bin/env python3
"""Does a reading's grammatical role, scored by the segmenter's own class transitions, help the embedding model?

Each candidate reading belongs to JMdict entries with parts of speech (様 read よう: noun; read さま: noun
suffix). Its role term is the mean over those classes of PMI(previous word's class -> role) + PMI(role -> next
word's class), from the dictionary's `segmenter_transitions`, the table the segmenter already prices cuts
with. The term is shared across every kanji, so it knows 'の + noun + に' beside a kanji with 36 tokens.
It is added to the per-kanji logistic regression's log-probability, times a weight tried over a grid.

  python3 role.py <work dir with tokens.pkl> <vectors.npz> <dictionary.sqlite> [C]

Same folds, MIN_TRAIN fallback and sign test as lr.py; every variant is compared with weight 0 (the shipped
model's shape) and with the control."""
import collections, os, sqlite3, sys, warnings
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sklearn.linear_model import LogisticRegression
from common import base_scores, compare, fit, fold_ranges, load_tokens, meaning_ambiguous
from cv import FOLDS, context_vectors
from lr import MIN_TRAIN, neighbour_vectors

warnings.filterwarnings('ignore')
WEIGHTS = (0.0, 0.25, 0.5, 1.0, 2.0)
# JMdict part-of-speech tag -> the segmenter's class name, in TransitionClass.tag's order of precedence.
ROLES = [('prt', 'prt'), ('cop', 'cop'), ('aux-v', 'aux-v'), ('aux-adj', 'aux-adj'), ('aux', 'aux'), ('conj', 'conj'),
         ('exp', 'exp'), ('v1', 'v1'), ('vk', 'vk'), ('vs-i', 'vs-i'), ('adj-ix', 'adj-i'), ('adj-i', 'adj-i'),
         ('adj-na', 'adj-na'), ('adj-no', 'adj-no'), ('adj-pn', 'adj-pn'), ('adj-t', 'adj-t'), ('adj-f', 'adj-f'),
         ('adv-to', 'adv-to'), ('adv', 'adv'), ('pn', 'pn'), ('n-suf', 'n-suf'), ('suf', 'suf'), ('n-pref', 'n-pref'),
         ('pref', 'pref'), ('ctr', 'ctr'), ('num', 'num'), ('int', 'int')]


def role_of(pos_tags):
    """The class one sense's JMdict tags name, by the segmenter's precedence; godan and other verbs fold to
    v5 and v-other, anything nounlike to n."""
    tags = set(pos_tags)
    for jmdict, name in ROLES:
        if jmdict in tags:
            return name
    if any(t.startswith('v5') for t in tags):
        return 'v5'
    if any(t.startswith('vs') for t in tags):
        return 'vs-i'
    if any(t.startswith('v') and t not in ('vt', 'vi') for t in tags):
        return 'v-other'
    if tags & {'n', 'n-adv', 'n-t', 'n-pr'}:
        return 'n'
    return 'unc'


def reading_roles(db_path):
    """{(kanji run, hiragana reading): set of classes} over every JMdict entry written with that run."""
    db = sqlite3.connect(db_path)
    out = collections.defaultdict(set)
    hira = lambda s: ''.join(chr(ord(c) - 0x60) if 'ァ' <= c <= 'ヶ' else c for c in s)
    senses = collections.defaultdict(set)
    for entry, pos in db.execute('SELECT entry_id, pos FROM senses WHERE pos IS NOT NULL'):
        senses[entry].add(role_of(pos.split(',')))
    for text, reading, entry in db.execute('SELECT k.text, kf.text, k.entry_id FROM kanji k JOIN kana_forms kf ON kf.entry_id = k.entry_id'):
        out[(text, hira(reading))] |= senses[entry]
    return out


def transitions(db_path):
    """{(previous class, next class): PMI} as the segmenter loads them."""
    return {(a, b): p for a, b, p in sqlite3.connect(db_path).execute('SELECT previous, next, pmi FROM segmenter_transitions')}


def pmi(table, a, b):
    """One transition's PMI, backing off from a fine class (adj-i:く) to its coarse class, then to 0."""
    for x in (a, a.split(':')[0]):
        for y in (b, b.split(':')[0]):
            if (x, y) in table:
                return table[(x, y)]
    return 0.0


def role_term(table, roles, token, reading):
    """Mean over the reading's classes of the transition into and out of it; 0 for a reading with no entry."""
    classes = roles.get((token['k'], reading)) or set()
    classes = classes - {'unc'}
    if not classes:
        return 0.0
    return sum(pmi(table, token['cls'][0], c) + pmi(table, c, token['cls'][1]) for c in classes) / len(classes)


def main(work, vec_path, db_path, c_value=10.0):
    """Runs the folds and prints, per weight, accuracy overall, on meaning-ambiguous kanji, and on 様."""
    cache = load_tokens(os.path.join(work, 'tokens.pkl'))
    tokens = cache['tokens']
    ambiguous = meaning_ambiguous(db_path, tokens)
    bag, _ = context_vectors(cache, vec_path, 5)
    X = np.hstack([neighbour_vectors(tokens, vec_path), bag])
    roles, table = reading_roles(db_path), transitions(db_path)
    by_kanji = collections.defaultdict(list)
    for n, t in enumerate(tokens):
        by_kanji[t['k']].append(n)
    hits = collections.defaultdict(dict)
    for f, (lo, hi) in enumerate(fold_ranges(len(tokens), FOLDS)):
        m = fit(tokens[:lo] + tokens[hi:])
        held = collections.defaultdict(list)
        for n in range(lo, hi):
            if len(m['readings'][tokens[n]['k']]) > 1:
                held[tokens[n]['k']].append(n)
        for k, ns in held.items():
            train = [i for i in by_kanji[k] if not lo <= i < hi]
            labels = [tokens[i]['r'] for i in train]
            fitted = len(train) >= MIN_TRAIN and len(set(labels)) > 1
            if fitted:
                clf = LogisticRegression(C=c_value, max_iter=200).fit(X[train], labels)
                logp = clf.predict_log_proba(X[ns])
            for j, n in enumerate(ns):
                t = tokens[n]
                parts = base_scores(m, t)
                control = {x: parts[x][0] + parts[x][1] for x in parts}
                hits['control'][n] = int(max(control, key=control.get) == t['r'])
                for w in WEIGHTS:
                    if fitted:
                        scores = {x: lp + w * role_term(table, roles, t, x) for x, lp in zip(clf.classes_, logp[j])}
                    else:
                        scores = {x: control[x] + w * role_term(table, roles, t, x) for x in control}
                    hits[f'lr+role {w}'][n] = int(max(scores, key=scores.get) == t['r'])
        print(f'fold {f + 1}/{FOLDS} done', flush=True)
    order = sorted(hits['control'])
    table_hits = {name: [h[n] for n in order] for name, h in hits.items()}
    meta = [tokens[n]['num_before'] or tokens[n]['num_after'] for n in order]
    clean = [i for i, num in enumerate(meta) if not num]
    subsets = (('OVERALL (no numeral gap)', clean),
               ('MEANING-AMBIGUOUS', [i for i in clean if tokens[order[i]]['k'] in ambiguous]),
               ('様 only', [i for i in clean if tokens[order[i]]['k'] == '様']),
               ('after の, any kanji', [i for i in clean if tokens[order[i]]['cls'][0] == 'w:の']))
    for title, subset in subsets:
        print(f'\n== {title}: right/total, accuracy, discordant vs weight 0, p')
        for name, h in table_hits.items():
            print(compare(name, h, table_hits['lr+role 0.0'], subset))


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4]) if len(sys.argv) > 4 else 10.0)
