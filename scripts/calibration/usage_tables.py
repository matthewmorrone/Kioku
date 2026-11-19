#!/usr/bin/env python3
"""Counts the dictionary's two usage tables from Tatoeba's Japanese indices. Resources/generate_db.py
calls build() near the end of a dictionary build and writes the result into the database:

  segmenter_transitions (previous, next, pmi)
      How much likelier word class B is directly after class A than the two meeting by chance, in
      nats: PMI = ln[(observed + SMOOTHING) / (expected + SMOOTHING)]. A pair is kept at up to four
      levels (full/full, full/coarse, coarse/full, coarse/coarse, where coarse drops a conjugating
      class's ending, "v5:て" → "v5") wherever that level has MIN_EVIDENCE observed or expected
      pairs; SegmenterTransitionTable backs off through the same levels in the same order. Counted
      from the training half (even sentence ids) minus train2k, which is kept for fitting.
  reading_contexts, word_vectors
      Which reading a kanji run takes from the words around it. reading_model.py fits them from the same
      counted sentences (every sentence no eval set uses) and from pretrained word vectors; see there.
      A conjugated token carries its dictionary form's reading (瞬いていた is marked 瞬く(またたく)), so its
      kanji run is read by cropping that reading to the stem, as the app's FuriganaResolver.inflectedStemReading
      does: 瞬いていた counts 瞬 → またた. Words whose stem itself changes when they inflect (JMdict vk and
      adj-ix: 来て is き, not 来る's く; 良かった is よ, not いい's い) are left out, as is any token whose kanji
      or leading kana don't match its headword's, unless the token is another kanji spelling the dictionary
      reads the same way (体(からだ) written 身体 counts 身体 → からだ).

Tatoeba's index tokenizes each sentence into JMdict headwords and marks a reading where a headword
has several (方(かた)), so it gives both word boundaries and readings. Word classes are named by the
app's own TransitionClass: segcli (scripts/segmentation-eval) is compiled from the app's sources and
classes every gold token against the database being built, so the tables always match the code and
the dictionary they ship with. The index skips names, numbers and punctuation; a gap between tokens,
like either end of a sentence, is the BOUNDARY class. The eval sets (scripts/segmentation-eval/data)
stay out of both tables."""
import collections, gzip, io, json, math, re

BOUNDARY = 'BOUNDARY'
SMOOTHING = 5.0
MIN_EVIDENCE = 5.0
LEXICAL_WORDS = 120
EVAL_SETS = ('held2k', 'fresh', 'kana2k', 'train2k')
FIT_SET = 'train2k'
KANJI = re.compile(r'[㐀-䶿一-鿿豈-﫿々]+')
INDEX_TOKEN = re.compile(r'^(?P<head>[^\(\[\{~|]+)(?:\|\d+)?(?:\((?P<read>[^)]*)\))?(?:\[(?P<sense>\d+)\])?(?:\{(?P<surf>[^}]*)\})?(?P<ok>~)?$')


def gold_sentences(index_lines, sentences):
    """Yields each indexed sentence as {"id", "s", "g": [[start, end, headword, reading, ok], …]}, offsets in
    code points. `sentences` maps a Tatoeba id (str) to its text; an index line whose sentence is
    missing, or whose tokens can't all be found in order, is skipped."""
    seen = set()
    for line in index_lines:
        fields = line.rstrip('\n').split('\t')
        if len(fields) < 3 or fields[0] in seen:
            continue
        text = sentences.get(fields[0])
        if text is None or '\n' in text:
            continue
        position, spans = 0, []
        for token in fields[2].split():
            match = INDEX_TOKEN.match(token)
            if not match:
                spans = None
                break
            surface = match.group('surf') or match.group('head')
            start = text.find(surface, position)
            if start < 0:
                spans = None
                break
            spans.append([start, start + len(surface), match.group('head'), match.group('read') or '', 1 if match.group('ok') else 0])
            position = start + len(surface)
        if not spans:
            continue
        seen.add(fields[0])
        yield {'id': fields[0], 's': text, 'g': spans}


def eval_records(data_dir):
    """The eval sets' sentences by set name, as {"ids", "texts"}."""
    records = {}
    for name in EVAL_SETS:
        ids, texts = set(), set()
        with gzip.open(data_dir / f'{name}.jsonl.gz', 'rt', encoding='utf-8') as f:
            for line in f:
                record = json.loads(line)
                ids.add(record['id'])
                texts.add(record['s'])
        records[name] = {'ids': ids, 'texts': texts}
    return records


def corpora(gold, data_dir):
    """Splits the gold sentences into the two counting corpora: (sentences for the readings, and for
    each of them whether the transitions count it too). Transitions: the training half (even ids) less
    train2k. Readings: those, plus held-out sentences (odd ids) that are in no eval set by id or text."""
    excluded = eval_records(data_dir)
    fit_ids = excluded[FIT_SET]['ids']
    excluded_ids = set().union(*(r['ids'] for r in excluded.values()))
    excluded_texts = set().union(*(r['texts'] for r in excluded.values()))
    counted, for_transitions = [], []
    for record in gold:
        if int(record['id']) % 2 == 0:
            if record['id'] in fit_ids:
                continue
            counted.append(record)
            for_transitions.append(True)
        elif record['id'] not in excluded_ids and record['s'] not in excluded_texts:
            counted.append(record)
            for_transitions.append(False)
    return counted, for_transitions


def lexical_words(records):
    """The LEXICAL_WORDS commonest gold tokens of 1–4 hiragana: each gets a class of its own."""
    counts = collections.Counter()
    for record in records:
        counts.update(record['s'][a:b] for a, b, *_ in record['g'])
    kana = re.compile(r'^[ぁ-ゖー]{1,4}$')
    return [word for word, _ in counts.most_common() if kana.match(word)][:LEXICAL_WORDS]


def coarse(name):
    """Mirrors TransitionClass.coarse: a word's own class has nothing coarser."""
    return name if name.startswith('w:') else name.split(':')[0]


# Separates a token's class from its lemma in `segcli count` output.
LEMMA_SEPARATOR = '\x1f'


def parse_tokens(line):
    """One `segcli count` line as [(start, end, class name, lemma or None), …]. segcli gives a lemma
    (Segmenter.preferredLemma) only where the class is not the word itself (w:の) or BOUNDARY."""
    tokens = []
    # Spaces only: str.split() would also cut at the lemma separator, which Python counts as whitespace.
    for part in filter(None, line.split(' ')):
        start, end, rest = part.split(',', 2)
        name, _, lemma = rest.partition(LEMMA_SEPARATOR)
        tokens.append((int(start), int(end), name, lemma or None))
    return tokens


def parse_classes(line):
    """One `segcli count` line as [(start, end, class name), …]."""
    return [(start, end, name) for start, end, name, _ in parse_tokens(line)]


def class_sequence(tokens):
    """A sentence's classes with BOUNDARY at both ends and at every gap between tokens."""
    sequence, position = [BOUNDARY], None
    for start, end, name in tokens:
        if position is not None and start != position and sequence[-1] != BOUNDARY:
            sequence.append(BOUNDARY)
        if name != BOUNDARY or sequence[-1] != BOUNDARY:
            sequence.append(name)
        position = end
    if sequence[-1] != BOUNDARY:
        sequence.append(BOUNDARY)
    return sequence


def transition_rows(class_lines):
    """(previous, next, pmi) rows, coarsest level first so a finer level's row for the same names wins."""
    sequences = [class_sequence(tokens) for tokens in map(parse_classes, class_lines) if tokens]
    identity = lambda name: name
    rows = {}
    for left_level, right_level in ((coarse, coarse), (coarse, identity), (identity, coarse), (identity, identity)):
        observed = collections.Counter()
        for sequence in sequences:
            observed.update((left_level(a), right_level(b)) for a, b in zip(sequence, sequence[1:]))
        total = sum(observed.values())
        left, right = collections.Counter(), collections.Counter()
        for (a, b), n in observed.items():
            left[a] += n
            right[b] += n
        for a in left:
            for b in right:
                expected = left[a] * right[b] / total
                if max(observed[(a, b)], expected) >= MIN_EVIDENCE:
                    rows[(a, b)] = round(math.log((observed[(a, b)] + SMOOTHING) / (expected + SMOOTHING)), 4)
    return [(a, b, pmi) for (a, b), pmi in sorted(rows.items())]


def to_hiragana(text):
    """Folds katakana to hiragana, the script the app compares readings in."""
    return ''.join(chr(ord(c) - 0x60) if 'ァ' <= c <= 'ヶ' else c for c in text)


def run_reading(word, reading):
    """The reading of `word`'s single kanji run: `reading` minus the kana before and after it."""
    runs = list(KANJI.finditer(word))
    if len(runs) != 1:
        return None
    before, after = to_hiragana(word[:runs[0].start()]), to_hiragana(word[runs[0].end():])
    reading = to_hiragana(reading)
    if not reading.startswith(before) or not reading.endswith(after):
        return None
    return reading[len(before):len(reading) - len(after)] or None


def surface_run(surface, headword, irregular):
    """The kanji run of a gold token written other than as its headword, when the headword's reading
    crops cleanly onto it: one run, the same kanji and the same leading kana in both, and kana after
    it in both (瞬く → 瞬いていた). The kanji's reading is then the headword's own stem, except in
    the `irregular` headwords, whose stem changes when they inflect. None for anything else: a
    different spelling (開ける → 明けて), a particle glued into the token (私 → 私の, where the
    neighbour classes would be a word off), a kana-only surface."""
    if headword in irregular or surface.startswith(headword):
        return None
    head_runs, surface_runs = list(KANJI.finditer(headword)), list(KANJI.finditer(surface))
    if len(head_runs) != 1 or len(surface_runs) != 1 or head_runs[0].group() != surface_runs[0].group():
        return None
    head, run = head_runs[0], surface_runs[0]
    if to_hiragana(headword[:head.start()]) != to_hiragana(surface[:run.start()]):
        return None
    if head.end() == len(headword) or run.end() == len(surface):
        return None
    return run.group()


def respelled_headword(surface, headword, reading, spellings):
    """The headword written with the token's own kanji, when the token uses another kanji spelling of
    it (体(からだ) written 身体, 張る(はる) written 貼って) and the dictionary lists that spelling with
    this reading: one kanji run in each, different kanji, the same kana before them, and the
    respelled headword with the token's reading among `spellings` ((spelling, hiragana reading)
    pairs). Its counts then go to the kanji as written, which furigana sees. None otherwise: a digit
    spelling (１日 for 一日), a token with a particle glued on, a spelling JMdict doesn't read so."""
    head_runs, surface_runs = list(KANJI.finditer(headword)), list(KANJI.finditer(surface))
    if len(head_runs) != 1 or len(surface_runs) != 1 or head_runs[0].group() == surface_runs[0].group():
        return None
    head, run = head_runs[0], surface_runs[0]
    if to_hiragana(headword[:head.start()]) != to_hiragana(surface[:run.start()]):
        return None
    candidate = headword[:head.start()] + run.group() + headword[head.end():]
    return candidate if (candidate, to_hiragana(reading)) in spellings else None


def build(index_lines, sentences, data_dir, classify):
    """The transition rows, and the counted sentences with their `segcli count` lines for reading_model.
    `classify(lexical words, records)` returns one `segcli count` line per record."""
    gold = list(gold_sentences(index_lines, sentences))
    counted, for_transitions = corpora(gold, data_dir)
    lexical = lexical_words([r for r, t in zip(counted, for_transitions) if t])
    class_lines = classify(lexical, counted)
    if len(class_lines) != len(counted):
        raise RuntimeError(f'segcli count returned {len(class_lines)} lines for {len(counted)} sentences')
    transitions = transition_rows([line for line, t in zip(class_lines, for_transitions) if t])
    return {'sentences': len(counted), 'transition_sentences': sum(for_transitions),
            'transitions': transitions, 'records': counted, 'class_lines': class_lines, 'lexical': lexical}
