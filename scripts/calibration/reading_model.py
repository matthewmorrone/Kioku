#!/usr/bin/env python3
"""Trains furigana's reading model from Tatoeba's gold readings and pretrained word vectors.

Resources/generate_db.py calls this after usage_tables.build. For every kanji run that Tatoeba reads
two or more ways, one multinomial logistic regression picks the reading from the words around the run:

    x = [ previous word (300) | next word (300) | previous is boundary | next is boundary | bag (300) ]

previous / next are the vectors of the words directly beside the run (zeros past the text, across text
the dictionary doesn't cover, or for a word without a vector). bag is the IDF-weighted mean of the
vectors of the words within WINDOW places either side, unit length. A word is its lemma
(Segmenter.preferredLemma, from `segcli count`) or, for a class that is the word itself (w:の), its
surface. Vectors are fastText cc.ja.300 (CC BY-SA 3.0), the VOCABULARY commonest of its words that the
dictionary spells, quantised to int8 / QUANTISATION: training sees exactly what the app dequantises.

The app (ReadingContextTable, ReadingContext) computes the same x and scores reading r as
bias_r + w_r . x; keep the two in step. Measured offline on 107k counted readings (scripts/segmentation-eval/cv):
the embeddings alone beat the former class + neighbour-word counts, +0.5 points overall and +0.6 on kanji whose
readings differ in meaning, in 9 of 10 folds.

Needs numpy and scikit-learn (requirements.txt)."""
import collections, math, re
import numpy as np
from sklearn.linear_model import LogisticRegression
import usage_tables as u

DIMENSIONS = 300
VOCABULARY = 50000
WINDOW = 5
QUANTISATION = 200.0
REGULARISATION = 10.0
MIN_TRAIN = 20
FEATURES = 3 * DIMENSIONS + 2
NUMERALS = set('0123456789０１２３４５６７８９〇一二三四五六七八九十百千万億兆')


def numeral_flags(record, i):
    """(numeral before token i, numeral after it, any text before, any text after) in the untokenised text
    between it and its neighbours. Tatoeba's index drops numbers, so 三人 has BOUNDARY before 人."""
    spans, text = record['g'], record['s']
    before = text[spans[i - 1][1] if i > 0 else 0:spans[i][0]]
    after = text[spans[i][1]:spans[i + 1][0] if i + 1 < len(spans) else len(text)]
    return any(c in NUMERALS for c in before), any(c in NUMERALS for c in after), bool(before), bool(after)


def training_tokens(records, class_lines, irregular, spellings):
    """One dict per countable gold reading, as usage_tables counted them: sentence id, kanji run, hiragana
    reading, the classes and lemmas either side, numeral/gap flags, and `window`, the (offset, word) of the
    tokens within WINDOW places. `class_lines` are `segcli count` output, one per record."""
    for record, line in zip(records, class_lines):
        parsed = {(a, b): (name, lemma) for a, b, name, lemma in u.parse_tokens(line)}
        spans = [(a, b) for a, b, *_ in record['g']]
        words = [parsed.get(span, (u.BOUNDARY, None)) for span in spans]
        surfaces = [record['s'][a:b] for a, b in spans]
        window_words = [lemma or surface for (_, lemma), surface in zip(words, surfaces)]

        def neighbour(i, step):
            """(class, lemma) of the adjacent token, BOUNDARY across a gap or past either end."""
            j = i + step
            if not 0 <= j < len(spans):
                return u.BOUNDARY, None
            joined = spans[j][0] == spans[i][1] if step > 0 else spans[j][1] == spans[i][0]
            return words[j] if joined else (u.BOUNDARY, None)
        for i, (a, b, headword, reading, *_) in enumerate(record['g']):
            if not reading or reading.startswith('#'):
                continue
            surface = surfaces[i]
            headword = u.respelled_headword(surface, headword, reading, spellings) or headword
            if surface == headword:
                runs = list(u.KANJI.finditer(headword))
                kanji = runs[0].group() if len(runs) == 1 else None
            else:
                kanji = u.surface_run(surface, headword, irregular)
            run = u.run_reading(headword, reading) if kanji else None
            if not (kanji and run):
                continue
            (prev_class, prev_lemma), (next_class, next_lemma) = neighbour(i, -1), neighbour(i, 1)
            num_before, num_after, gap_before, gap_after = numeral_flags(record, i)
            yield dict(sid=int(record['id']), k=kanji, r=run, cls=(prev_class, next_class), words=(prev_lemma, next_lemma),
                       num_before=num_before, num_after=num_after, gap_before=gap_before, gap_after=gap_after,
                       window=[(o, window_words[i + o]) for o in range(-WINDOW, WINDOW + 1) if o and 0 <= i + o < len(spans)])


def inverse_document_frequency(records, class_lines):
    """({word: ln(sentences / (sentences containing it + 1))}, the weight of an unseen word). A word is its
    lemma or surface as in the windows."""
    frequency = collections.Counter()
    for record, line in zip(records, class_lines):
        frequency.update({lemma or record['s'][a:b] for a, b, _, lemma in u.parse_tokens(line)})
    total = len(records)
    return {w: math.log(total / (n + 1)) for w, n in frequency.items()}, math.log(total)


def read_vectors(stream, accepted):
    """{word: int8 array} for the first VOCABULARY words of a fastText .vec text stream that are in `accepted`
    (the dictionary's spellings), each vector scaled to unit length and quantised."""
    vectors = {}
    next(stream)
    for line in stream:
        word, _, rest = line.partition(' ')
        if word not in accepted:
            continue
        v = np.array(rest.split(), dtype=np.float32)
        norm = np.linalg.norm(v)
        if norm == 0 or v.shape[0] != DIMENSIONS:
            continue
        vectors[word] = np.clip(np.rint(v / norm * QUANTISATION), -127, 127).astype(np.int8)
        if len(vectors) >= VOCABULARY:
            break
    return vectors


def feature_rows(tokens, vectors, idf, unseen_idf):
    """(len(tokens) x FEATURES) float32 matrix of x, as the app builds it."""
    lookup = {w: v.astype(np.float32) / QUANTISATION for w, v in vectors.items()}
    out = np.zeros((len(tokens), FEATURES), dtype=np.float32)
    for n, t in enumerate(tokens):
        for slot in (0, 1):
            if t['cls'][slot] == u.BOUNDARY:
                out[n, 2 * DIMENSIONS + slot] = 1
        # Offsets -1 and +1 are the neighbours; a boundary neighbour keeps a zero vector.
        near = {o: w for o, w in t['window'] if o in (-1, 1)}
        for slot, offset in enumerate((-1, 1)):
            if t['cls'][slot] != u.BOUNDARY and near.get(offset) in lookup:
                out[n, slot * DIMENSIONS:(slot + 1) * DIMENSIONS] = lookup[near[offset]]
        bag = np.zeros(DIMENSIONS, dtype=np.float32)
        for _, w in t['window']:
            if w in lookup:
                bag += idf.get(w, unseen_idf) * lookup[w]
        norm = np.linalg.norm(bag)
        if norm > 0:
            out[n, 2 * DIMENSIONS + 2:] = bag / norm
    return out


def reading_rows(tokens, vectors, idf, unseen_idf, extra_tokens=()):
    """(kanji, reading, count, bias, weights blob or None) for every counted reading, and a model (float32
    FEATURES weights and a bias per reading) for each kanji with 2+ readings and MIN_TRAIN tokens. Only logit
    differences between a kanji's readings matter, so a two-reading kanji stores zeros for its first.

    `extra_tokens` (NDL titles, ndl_corpus.py) join the fit with a source column, 1 for them and 0 for `tokens`.
    The column carries the extra source's own reading frequencies, so the shared weights learn from its contexts
    while the bias stays `tokens`'s: the stored weights drop the column, which is 0 wherever the app scores.
    Counts stay `tokens`'s, and a kanji needs two readings among `tokens` to get a model."""
    counts = collections.Counter((t['k'], t['r']) for t in tokens)
    both = list(tokens) + list(extra_tokens)
    by_kanji = collections.defaultdict(list)
    for n, t in enumerate(both):
        by_kanji[t['k']].append(n)
    own_readings = collections.defaultdict(set)
    for t in tokens:
        own_readings[t['k']].add(t['r'])
    X = feature_rows(both, vectors, idf, unseen_idf)
    source = (np.arange(len(both)) >= len(tokens)).astype(np.float32)[:, None]
    models = {}
    for kanji, indices in by_kanji.items():
        labels = [both[i]['r'] for i in indices]
        if len(indices) < MIN_TRAIN or len(own_readings[kanji]) < 2 or len(set(labels)) < 2:
            continue
        rows = np.hstack([X[indices], source[indices]]) if extra_tokens else X[indices]
        clf = LogisticRegression(C=REGULARISATION, max_iter=200).fit(rows, labels)
        coef = clf.coef_[:, :FEATURES]
        if len(clf.classes_) == 2:
            weights = np.vstack([np.zeros(FEATURES), coef[0]])
            biases = [0.0, float(clf.intercept_[0])]
        else:
            weights, biases = coef, [float(b) for b in clf.intercept_]
        for r, w, b in zip(clf.classes_, weights, biases):
            models[(kanji, r)] = (b, np.asarray(w, dtype='<f4').tobytes())
    return [(k, r, n, *(models.get((k, r)) or (0.0, None))) for (k, r), n in sorted(counts.items())]


def word_vector_rows(vectors, idf, unseen_idf):
    """(word, idf, int8 vector blob) per vocabulary word, for the dictionary's word_vectors table."""
    return [(w, idf.get(w, unseen_idf), v.tobytes()) for w, v in sorted(vectors.items())]
