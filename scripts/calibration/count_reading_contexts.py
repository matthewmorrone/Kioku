#!/usr/bin/env python3
"""Builds the furigana reading-context table (Kioku/Read/Furigana/reading-contexts.tsv).

Tatoeba's index marks the reading of every headword that has more than one (時(じ), 方(かた)), so
its sentences say which reading a kanji takes next to which word classes. The same inputs as
the transition table (fit_transition_costs.py), so every class name comes from the app's own
TransitionClass code:

  count_reading_contexts.py corpus train.jsonl held.jsonl work/data/*.jsonl > counts.jsonl
      prep.py's two halves: train.jsonl without its first 2,000 lines (train2k, kept for fitting),
      plus every held.jsonl sentence that is in none of the eval sets named after it (held2k,
      fresh, kana2k, train2k), by id or text. 137,836 sentences on 2026-10-10.
  segcli count lexical.txt < counts.jsonl > classes.txt
      lexical.txt = the "w:" words of segmenter-transitions.tsv
  count_reading_contexts.py count counts.jsonl classes.txt > reading-contexts.tsv

One row per kanji run and reading: "kanji <tab> reading <tab> count <tab> previous classes <tab>
next classes", each class list "name=count" separated by spaces. The reading is the kanji run's own
(the headword's reading less its kana, 来る くる → く), in hiragana. As in the transition table, a
token with a gap before or after it (a number, a name, punctuation) has BOUNDARY there.
ReadingContextTable reads it. Counting the unused held-out sentences too (2026-10-10, 71,401 →
137,836) moved score_readings.py from held2k 95.12% / fresh5k 96.85% to 95.19% / 96.90%. Only tokens
written as their headword are counted: a conjugated token is marked with its dictionary form's reading
(来て as 来る(くる)), which counted 来 → く for 来て.
"""
import collections, json, re, sys

KANJI = re.compile(r'[㐀-䶿一-鿿豈-﫿々]+')
BOUNDARY = 'BOUNDARY'


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


def corpus(train_path, held_path, excluded_paths):
    """Writes the sentences to count: train minus train2k, plus held-out sentences no eval set uses."""
    excluded_ids, excluded_text = set(), set()
    for path in excluded_paths:
        for line in open(path):
            record = json.loads(line)
            excluded_ids.add(record['id']); excluded_text.add(record['s'])
    sys.stdout.writelines(open(train_path).readlines()[2000:])
    for line in open(held_path):
        record = json.loads(line)
        if record['id'] not in excluded_ids and record['s'] not in excluded_text:
            sys.stdout.write(line)


def count(gold_path, classes_path):
    """Prints one row per kanji run and reading with the classes seen either side of it."""
    occurrences = collections.Counter()
    previous = collections.defaultdict(collections.Counter)
    following = collections.defaultdict(collections.Counter)
    for gold_line, classes_line in zip(open(gold_path), open(classes_path)):
        record = json.loads(gold_line)
        class_by_span = {}
        for part in classes_line.split():
            a, b, name = part.split(',', 2)
            class_by_span[(int(a), int(b))] = name
        spans = [(a, b) for a, b, *_ in record['g']]
        for i, (a, b, headword, reading, *_) in enumerate(record['g']):
            # Empty, or an entry-number pointer (#1392580) rather than a reading.
            if not reading or reading.startswith('#'):
                continue
            # Only tokens written as their headword: a conjugated token carries its dictionary
            # form's reading (来て marked 来る(くる)), which is the kanji's reading in that form only
            # when the verb doesn't change it, so 来る's き and こ were counted as く.
            if record['s'][a:b] != headword:
                continue
            runs, head_runs = list(KANJI.finditer(record['s'][a:b])), list(KANJI.finditer(headword))
            if len(runs) != 1 or len(head_runs) != 1 or head_runs[0].group() != runs[0].group():
                continue
            run = run_reading(headword, reading)
            if run is None:
                continue
            key = (runs[0].group(), run)
            before = class_by_span.get(spans[i - 1], BOUNDARY) if i > 0 and spans[i - 1][1] == a else BOUNDARY
            after = class_by_span.get(spans[i + 1], BOUNDARY) if i + 1 < len(spans) and spans[i + 1][0] == b else BOUNDARY
            occurrences[key] += 1
            previous[key][before] += 1
            following[key][after] += 1
    for key in sorted(occurrences):
        def classes(counter):
            return ' '.join(f'{name}={n}' for name, n in sorted(counter.items()))
        print(f'{key[0]}\t{key[1]}\t{occurrences[key]}\t{classes(previous[key])}\t{classes(following[key])}')


if __name__ == '__main__':
    if sys.argv[1] == 'corpus':
        corpus(sys.argv[2], sys.argv[3], sys.argv[4:])
    else:
        count(sys.argv[2], sys.argv[3])
