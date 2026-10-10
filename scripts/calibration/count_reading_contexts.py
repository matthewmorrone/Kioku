#!/usr/bin/env python3
"""Builds the furigana reading-context table (Kioku/Read/Furigana/reading-contexts.tsv).

Tatoeba's index marks the reading of every headword that has more than one (時(じ), 方(かた)), so
the training half says which reading a kanji takes next to which word classes. The same inputs as
the transition table (fit_transition_costs.py), so every class name comes from the app's own
TransitionClass code:

  segcli count lexical.txt < train-counts.jsonl > classes.txt
      lexical.txt = the "w:" words of segmenter-transitions.tsv; train-counts.jsonl = train.jsonl
      without its first 2,000 lines (train2k, kept out of all counts)
  count_reading_contexts.py train-counts.jsonl classes.txt > reading-contexts.tsv

One row per kanji run and reading: "kanji <tab> reading <tab> count <tab> previous classes <tab>
next classes", each class list "name=count" separated by spaces. The reading is the kanji run's own
(the headword's reading less its kana, 来る くる → く), in hiragana. As in the transition table, a
token with a gap before or after it (a number, a name, punctuation) has BOUNDARY there.
ReadingContextTable reads it; held2k 91.09% → 94.50% and fresh5k 94.79% → 96.97% on
score_readings.py when measured on their own.
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


def main():
    gold_path, classes_path = sys.argv[1], sys.argv[2]
    count = collections.Counter()
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
            runs, head_runs = list(KANJI.finditer(record['s'][a:b])), list(KANJI.finditer(headword))
            if len(runs) != 1 or len(head_runs) != 1 or head_runs[0].group() != runs[0].group():
                continue
            run = run_reading(headword, reading)
            if run is None:
                continue
            key = (runs[0].group(), run)
            before = class_by_span.get(spans[i - 1], BOUNDARY) if i > 0 and spans[i - 1][1] == a else BOUNDARY
            after = class_by_span.get(spans[i + 1], BOUNDARY) if i + 1 < len(spans) and spans[i + 1][0] == b else BOUNDARY
            count[key] += 1
            previous[key][before] += 1
            following[key][after] += 1
    for key in sorted(count):
        def classes(counter):
            return ' '.join(f'{name}={n}' for name, n in sorted(counter.items()))
        print(f'{key[0]}\t{key[1]}\t{count[key]}\t{classes(previous[key])}\t{classes(following[key])}')


if __name__ == '__main__':
    main()
