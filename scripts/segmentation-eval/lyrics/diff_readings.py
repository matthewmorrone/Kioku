#!/usr/bin/env python3
"""Which lyric readings a furigana change moves: the check to run before shipping any reading change.

Tatoeba (score_readings.py) has no song lyrics, and lyrics drop particles and use words Tatoeba rarely
sees, so a reading change can be net-positive there and still break a lyric (切なくて read きなくて,
2026-10-15). There is no lyric reading gold; this lists every change for a person to judge.

    python3 lyrics/diff_readings.py --text > work/lyrics.txt          # the lyric lines, one per line
    ./work/segcli furigana < work/lyrics.txt > work/lyrics.before     # with the shipped code
    ./work/segcli furigana < work/lyrics.txt > work/lyrics.after      # with the change
    python3 lyrics/diff_readings.py work/lyrics.txt work/lyrics.before work/lyrics.after

Prints each changed reading as `kanji: before → after` with how many lines it changed on, never the
lyric lines themselves.
"""
import collections
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REVIEW = os.path.join(HERE, 'review-corrected-2026-09-20.txt')


def lyric_lines():
    """The lyric lines of the review file, without its cut marks and flags."""
    lines = []
    for raw in open(REVIEW, encoding='utf-8'):
        if raw.startswith('#') or not raw.strip():
            continue
        text = raw.rstrip('\n')
        if text.startswith('?'):
            text = text[1:]
        lines.append(text.strip().replace(' | ', ''))
    return lines


def readings(path):
    """Per line, {(UTF-16 location, length): reading} from `segcli furigana` output."""
    out = []
    for raw in open(path, encoding='utf-8'):
        out.append({(loc, length): reading for loc, length, reading in json.loads(raw)})
    return out


def utf16_slice(text, location, length):
    """The characters at a UTF-16 location and length, as segcli reports them."""
    encoded = text.encode('utf-16-le')
    return encoded[location * 2:(location + length) * 2].decode('utf-16-le')


def main():
    if sys.argv[1:] == ['--text']:
        print('\n'.join(lyric_lines()))
        return
    text_path, before_path, after_path = sys.argv[1:4]
    texts = [line.rstrip('\n') for line in open(text_path, encoding='utf-8')]
    changes = collections.Counter()
    for text, before, after in zip(texts, readings(before_path), readings(after_path)):
        for key in sorted(set(before) | set(after)):
            if before.get(key) != after.get(key):
                kanji = utf16_slice(text, *key)
                changes[(kanji, before.get(key, '-'), after.get(key, '-'))] += 1
    if not changes:
        print('no lyric reading changed')
    for (kanji, old, new), count in sorted(changes.items()):
        print(f'{kanji}: {old} → {new}' + (f'  ×{count}' if count > 1 else ''))


if __name__ == '__main__':
    main()
