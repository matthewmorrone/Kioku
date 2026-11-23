"""Shared pieces of the offline reading-choice cross-validation: loading the cached tuples, the counts the
app's ReadingContextTable reads (fit), its two scores (class terms and the neighbour-word adjustment),
the folds, the meaning-ambiguous kanji set, and the exact sign test every comparison uses."""
import collections, math, pickle, sqlite3

SMOOTH, CAP, BETA = 0.2, 3000.0, 1.0


def load_tokens(path):
    """The cached run from tokens.py: {'tokens': [...], 'idf': {...}} with tokens in sentence-id order."""
    with open(path, 'rb') as f:
        return pickle.load(f)


def fit(tokens):
    """The counts ReadingContextTable holds: occurrences per (kanji, reading), neighbour classes per slot
    (0 previous, 1 next), neighbour (class, lemma) pairs per slot, and the readings seen for each kanji."""
    m = dict(occ=collections.Counter(), cls=[collections.defaultdict(collections.Counter) for _ in range(2)],
             word=[collections.defaultdict(collections.Counter) for _ in range(2)], classes=[set(), set()])
    for t in tokens:
        key = (t['k'], t['r'])
        m['occ'][key] += 1
        for s in range(2):
            c = t['cls'][s]
            m['cls'][s][key][c] += 1
            m['classes'][s].add(c)
            if t['words'][s]:
                m['word'][s][key][(c, t['words'][s])] += 1
    m['readings'] = collections.defaultdict(list)
    for k, r in sorted(m['occ']):
        m['readings'][k].append(r)
    return m


def class_term(m, s, k, r, c):
    """The shipped smoothed, capped log P(class | reading) for neighbour slot s."""
    sightings = min(m['occ'][(k, r)], CAP)
    seen = min(m['cls'][s][(k, r)][c], sightings)
    return math.log((seen + SMOOTH) / (sightings + SMOOTH * len(m['classes'][s])))


def word_term(m, s, k, r, c, w, options):
    """The shipped neighbour-word adjustment: log of the lemma's observed over expected count beside r."""
    if w is None or c.startswith('w:') or c == 'BOUNDARY':
        return 0.0
    seen_w = sum(m['word'][s][(k, x)][(c, w)] for x in options)
    if seen_w == 0:
        return 0.0
    share = (seen_w + 1) / (sum(m['cls'][s][(k, x)][c] for x in options) + 1)
    expected = m['occ'][(k, r)] * math.exp(class_term(m, s, k, r, c)) * share
    return math.log((m['word'][s][(k, r)][(c, w)] + BETA) / (expected + BETA))


def base_scores(m, t):
    """Per candidate reading: (prior + class terms, word adjustment, prior), the app's score without Apple's vote.
    Candidates are the readings the training folds saw for the kanji."""
    k = t['k']
    options = m['readings'][k]
    total = sum(m['occ'][(k, x)] for x in options)
    out = {}
    for x in options:
        prior = math.log((m['occ'][(k, x)] + 1) / (total + len(options)))
        classes = class_term(m, 0, k, x, t['cls'][0]) + class_term(m, 1, k, x, t['cls'][1])
        words = word_term(m, 0, k, x, t['cls'][0], t['words'][0], options) + word_term(m, 1, k, x, t['cls'][1], t['words'][1], options)
        out[x] = (prior + classes, words, prior)
    return out


def fold_ranges(n, folds):
    """FOLDS contiguous index blocks: a sentence's tokens and neighbouring ids stay in one fold."""
    size = math.ceil(n / folds)
    return [(f * size, min(n, (f + 1) * size)) for f in range(folds)]


def sign_test(b, c):
    """Exact two-sided sign test on b wins against c losses (the discordant tokens)."""
    n = b + c
    if n == 0:
        return 1.0
    tail = sum(math.comb(n, i) for i in range(min(b, c) + 1))
    return min(1.0, 2 * tail / 2 ** n)


def meaning_ambiguous(db_path, tokens, minimum=10):
    """The kanji runs whose commonly counted readings belong to different JMdict entries written with
    that exact run (人気 にんき / ひとけ, 生物 せいぶつ / なまもの): derived from the dictionary and the
    counts, no list. A reading counts as common with `minimum` occurrences in the whole counted corpus.
    Runs that are only a verb stem (行 in 行く/行う) have no standalone entry and so are not included."""
    counts = collections.Counter((t['k'], t['r']) for t in tokens)
    db = sqlite3.connect(db_path)
    entry_readings = collections.defaultdict(set)
    for text, reading, entry in db.execute('SELECT k.text, kf.text, k.entry_id FROM kanji k JOIN kana_forms kf ON kf.entry_id = k.entry_id'):
        entry_readings[text].add((entry, ''.join(chr(ord(ch) - 0x60) if 'ァ' <= ch <= 'ヶ' else ch for ch in reading)))
    runs = set()
    for (k, r), n in counts.items():
        if n >= minimum:
            runs.add(k)
    result = set()
    for k in runs:
        entries = {e for e, r in entry_readings.get(k, ()) if counts[(k, r)] >= minimum}
        if len(entries) >= 2:
            result.add(k)
    return result


def compare(label, hits, ref, subset=None):
    """One result row: right/total, accuracy, discordant wins/losses against ref and the sign-test p."""
    idx = range(len(hits)) if subset is None else subset
    right = sum(hits[i] for i in idx)
    b = sum(1 for i in idx if hits[i] > ref[i])
    c = sum(1 for i in idx if hits[i] < ref[i])
    n = len(idx)
    return f'{label:34} {right:6}/{n:<6} {100 * right / max(n, 1):7.3f}%  +{b:<4} -{c:<4} p={sign_test(b, c):.3g}'
