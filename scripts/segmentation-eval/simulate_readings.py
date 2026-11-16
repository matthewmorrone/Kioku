#!/usr/bin/env python3
"""Replays the contextual reading decisions dumped by `segcli readings-json` under a scoring variant,
and writes `segcli furigana`-style output for score_readings.py or lyrics/diff_readings.py. Lets a
change to ReadingContextTable's scoring be measured in seconds instead of a rebuild per setting.

    ./work/segcli readings-json < work/data/train2k.txt > work/train2k.decisions
    python3 simulate_readings.py work/train2k.decisions --cap 100 > work/train2k.sim
    python3 score_readings.py work/data/train2k.jsonl work/train2k.sim

Variants: --cap K counts a reading as seen at most K times in its class terms' denominator (how much
an unseen neighbour can count against a common reading); --apple V sets Apple's vote; --smoothing S
the class pseudo-count; --phrase V the vote for readings that spell a dictionary expression when several do (one decides outright)
(PhraseReadingEvidence; 0 turns phrases off). The defaults reproduce the shipped scoring: at the shipped
cap and smoothing the neighbour terms are the app's own from the dump (neighbour words included); any
other --cap or --smoothing replays the class-only model from the raw counts.
"""
import argparse
import json
import math
import sys


def hiragana(text):
    """Folds katakana to hiragana, as KanaNormalizer does."""
    return ''.join(chr(ord(c) - 0x60) if 'ァ' <= c <= 'ヶ' else c for c in text)


def choose(decision, cap, apple_vote, smoothing, phrase_vote=2.0):
    """The reading a decision picks under the variant: its candidates' best total, earlier on ties."""
    best = None
    for c in decision['candidates']:
        n = c['n']
        prior = math.log((n + c['added'] + 1) / (c['total'] + c['k']))
        if 'previousTerm' in c and cap == 3000.0 and smoothing == 0.2:
            # The app's own neighbour terms (classes moved by the neighbour words' counts), as the dump
            # records them: only the class model is replayed from counts.
            term = c['previousTerm'] + c['nextTerm']
        else:
            denominator = min(n, cap) if cap is not None else n
            term = 0.0
            for seen in (c['prevSeen'], c['nextSeen']):
                observed = min(seen, denominator) if cap is not None else seen
                term += math.log((observed + smoothing) / (denominator + smoothing * c['classes']))
        total = prior + term + (apple_vote if c['reading'] == decision['apple'] else 0)
        total += phrase_vote if c['reading'] in decision.get('phrase', []) else 0
        if best is None or total > best[1]:
            best = (c['reading'], total)
    return best[0] if best else decision['fallback']


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('decisions')
    parser.add_argument('--cap', type=float, default=None)
    parser.add_argument('--apple', type=float, default=2.0)
    parser.add_argument('--smoothing', type=float, default=0.2)
    parser.add_argument('--phrase', type=float, default=2.0)
    args = parser.parse_args()
    for line in open(args.decisions, encoding='utf-8'):
        record = json.loads(line)
        rows = {(loc, length): reading for loc, length, reading in record['furigana']}
        for decision in record['decisions']:
            key = (decision['location'], decision['length'])
            # The one reading that spells a phrase decides (unless phrases are off); else the counts, and
            # for a kanji the counts never saw, Apple's reading.
            phrase = decision.get('phrase', [])
            if len(phrase) == 1 and args.phrase > 0:
                chosen = phrase[0]
            elif decision['candidates']:
                chosen = choose(decision, args.cap, args.apple, args.smoothing, args.phrase)
            else:
                chosen = decision['apple']
            # The app keeps the reading build gave when the choice is the same sound (ホンコン, ほんこん).
            if chosen and chosen != hiragana(rows.get(key, '')):
                rows[key] = chosen
        sys.stdout.write(json.dumps([[loc, length, reading] for (loc, length), reading in sorted(rows.items())], ensure_ascii=False) + '\n')


if __name__ == '__main__':
    main()
