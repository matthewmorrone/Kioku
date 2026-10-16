#!/usr/bin/env python3
"""Replays the contextual reading decisions dumped by `segcli readings-json` under a scoring variant,
and writes `segcli furigana`-style output for score_readings.py or lyrics/diff_readings.py. Lets a
change to ReadingContextTable's scoring be measured in seconds instead of a rebuild per setting.

    ./work/segcli readings-json < work/data/train2k.txt > work/train2k.decisions
    python3 simulate_readings.py work/train2k.decisions --cap 100 > work/train2k.sim
    python3 score_readings.py work/data/train2k.jsonl work/train2k.sim

Variants: --cap K counts a reading as seen at most K times in its class terms' denominator (how much
an unseen neighbour can count against a common reading); --apple V sets Apple's vote; --smoothing S
the class pseudo-count. The defaults reproduce the shipped scoring.
"""
import argparse
import json
import math
import sys


def hiragana(text):
    """Folds katakana to hiragana, as KanaNormalizer does."""
    return ''.join(chr(ord(c) - 0x60) if 'ァ' <= c <= 'ヶ' else c for c in text)


def choose(decision, cap, apple_vote, smoothing):
    """The reading a decision picks under the variant: its candidates' best total, earlier on ties."""
    best = None
    for c in decision['candidates']:
        n = c['n']
        prior = math.log((n + c['added'] + 1) / (c['total'] + c['k']))
        denominator = min(n, cap) if cap is not None else n
        term = 0.0
        for seen in (c['prevSeen'], c['nextSeen']):
            observed = min(seen, denominator) if cap is not None else seen
            term += math.log((observed + smoothing) / (denominator + smoothing * c['classes']))
        total = prior + term + (apple_vote if c['reading'] == decision['apple'] else 0)
        if best is None or total > best[1]:
            best = (c['reading'], total)
    return best[0] if best else decision['fallback']


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('decisions')
    parser.add_argument('--cap', type=float, default=None)
    parser.add_argument('--apple', type=float, default=2.0)
    parser.add_argument('--smoothing', type=float, default=0.2)
    args = parser.parse_args()
    for line in open(args.decisions, encoding='utf-8'):
        record = json.loads(line)
        rows = {(loc, length): reading for loc, length, reading in record['furigana']}
        for decision in record['decisions']:
            key = (decision['location'], decision['length'])
            chosen = choose(decision, args.cap, args.apple, args.smoothing) if decision['candidates'] else decision['apple']
            # The app keeps the reading build gave when the choice is the same sound (ホンコン, ほんこん).
            if chosen and chosen != hiragana(rows.get(key, '')):
                rows[key] = chosen
        sys.stdout.write(json.dumps([[loc, length, reading] for (loc, length), reading in sorted(rows.items())], ensure_ascii=False) + '\n')


if __name__ == '__main__':
    main()
