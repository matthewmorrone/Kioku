#!/usr/bin/env python3
"""Scores the Read view's furigana against the gold readings in a Tatoeba set.

Tatoeba's indices give a reading only where the headword has more than one (二十歳 → はたち), so this
measures exactly the reading choices that can go wrong. Only gold tokens with one kanji run are
scored: the expected ruby is the gold reading cropped to that run, using the headword's okurigana.

    ./work/segcli furigana < work/data/held2k.txt > work/held2k.furigana
    python3 score_readings.py work/data/held2k.jsonl work/held2k.furigana [--examples N]
"""
import json
import re
import sys

KANJI = re.compile(r'[㐀-䶿一-鿿豈-﫿々]+')


def to_hiragana(text):
    """Folds katakana to hiragana so a reading compares the same in either script."""
    return ''.join(chr(ord(c) - 0x60) if 'ァ' <= c <= 'ヶ' else c for c in text)


def run_reading(word, reading):
    """The reading of `word`'s single kanji run: `reading` minus the kana before and after it."""
    runs = list(KANJI.finditer(word))
    if len(runs) != 1:
        return None
    before = to_hiragana(word[:runs[0].start()])
    after = to_hiragana(word[runs[0].end():])
    reading = to_hiragana(reading)
    if not reading.startswith(before) or not reading.endswith(after):
        return None
    core = reading[len(before):len(reading) - len(after)]
    return core or None


def main():
    gold_path, ours_path = sys.argv[1], sys.argv[2]
    examples = int(sys.argv[sys.argv.index('--examples') + 1]) if '--examples' in sys.argv else 0
    correct = wrong = missing = 0
    shown = 0
    with open(gold_path) as gold_file, open(ours_path) as ours_file:
        for gold_line, ours_line in zip(gold_file, ours_file):
            record = json.loads(gold_line)
            sentence = record['s']
            ours = {loc: (length, reading) for loc, length, reading in json.loads(ours_line)}
            for start, end, headword, reading, *_ in record['g']:
                # Empty, or an entry-number pointer (#1392580) rather than a reading.
                if not reading or reading.startswith('#'):
                    continue
                surface = sentence[start:end]
                runs = list(KANJI.finditer(surface))
                if len(runs) != 1:
                    continue
                # The headword's okurigana crops the reading; the surface's kanji run must be the
                # headword's, or the gold reading isn't about this run.
                head_runs = list(KANJI.finditer(headword))
                if len(head_runs) != 1 or head_runs[0].group() != runs[0].group():
                    continue
                expected = run_reading(headword, reading)
                if expected is None:
                    continue
                got = ours.get(start + runs[0].start())
                if got is None:
                    missing += 1
                    verdict = 'missing'
                elif to_hiragana(got[1]) == expected:
                    correct += 1
                    continue
                else:
                    wrong += 1
                    verdict = f'got {got[1]}'
                if shown < examples:
                    shown += 1
                    print(f'  {surface}: want {expected}, {verdict}  in {sentence}')
    total = correct + wrong + missing
    print(f'scored {total}  correct {correct} ({100 * correct / max(total, 1):.2f}%)  wrong {wrong}  missing {missing}')


if __name__ == '__main__':
    main()
