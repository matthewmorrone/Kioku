#!/usr/bin/env python3
"""Turns the sampled NDL titles (ndl_extract.py) into tokens shaped like tokens.py's, so they can join the
training folds. Each title is segmented by the shipped segmenter (`segcli run`), the segments are classed
and lemmatised by `segcli count` (spans as gold), and every ruby pair whose kanji run is exactly one
segment's only kanji run becomes a token: (kanji run, reading) from the ruby markup, the neighbouring
segments' classes and lemmas, and the +-WINDOW lemma window. Sentence ids are 10**9 + title number, so they
never collide with Tatoeba's.

  python3 ndl_tokens.py <ndl_sample.jsonl> <dictionary.sqlite> <segcli> <lexical.txt> <tokens.pkl> <out.pkl> [per_key] [max_length]

`segcli run` costs ~1 min per 2k sentences, so the sample is cut first: per (kanji, reading) key the PER_KEY shortest
titles of at most MAX_LENGTH characters (a reading with fewer examples keeps them all).

Run one segcli at a time (shared UserDefaults)."""
import json, os, pickle, subprocess, sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'scripts' / 'calibration'))
import usage_tables as u

SEPARATOR = '\x1e'
WINDOW = 5
PER_KEY = 80
MAX_LENGTH = 45


def run_segcli(segcli, db_path, args, text):
    """Output lines of one segcli invocation fed `text`."""
    p = subprocess.run([segcli, *args], input=text, capture_output=True, text=True,
                       env=dict(os.environ, DB=db_path, SWIFT_DETERMINISTIC_HASHING='1'))
    if p.returncode != 0:
        raise RuntimeError(p.stderr[-2000:])
    return p.stdout.split('\n')[:-1]


def reduce(rows, tokens_path):
    """The titles kept: for each (kanji, reading) of a kanji Tatoeba reads 2+ ways, the PER_KEY shortest titles."""
    readings = {}
    for t in pickle.load(open(tokens_path, 'rb'))['tokens']:
        readings.setdefault(t['k'], set()).add(t['r'])
    readings = {k: rs for k, rs in readings.items() if len(rs) > 1}
    by_key = {}
    for i, row in enumerate(rows):
        if len(row['s']) > MAX_LENGTH:
            continue
        for k, r in {(k, r) for k, r in row['pairs'] if k in readings and r in readings[k]}:
            by_key.setdefault((k, r), []).append((len(row['s']), i))
    keep = {i for entries in by_key.values() for _, i in sorted(entries)[:PER_KEY]}
    return [rows[i] for i in sorted(keep)]


def main(sample_path, db_path, segcli, lexical_path, tokens_path, out_path, per_key=None, max_length=None):
    """Cuts the sample, segments, classes, aligns the ruby pairs and pickles the tokens. `per_key` and `max_length`
    override the cut's defaults (a huge pair keeps every title the extraction sampled)."""
    global PER_KEY, MAX_LENGTH
    PER_KEY = int(per_key) if per_key else PER_KEY
    MAX_LENGTH = int(max_length) if max_length else MAX_LENGTH
    rows = reduce([json.loads(line) for line in open(sample_path, encoding='utf-8')], tokens_path)
    print(f'{len(rows)} titles after the per-key cut', flush=True)
    titles = [r['s'].replace('\n', ' ') for r in rows]
    segmented = run_segcli(segcli, db_path, ['run'], '\n'.join(titles) + '\n')
    if len(segmented) != len(titles):
        raise RuntimeError(f'segcli run returned {len(segmented)} lines for {len(titles)} titles')
    records, spans_of = [], []
    for i, (title, line) in enumerate(zip(titles, segmented)):
        pieces = line.split(SEPARATOR)
        if ''.join(pieces) != title:
            spans_of.append(None)
            records.append({'s': title, 'g': []})
            continue
        spans, position = [], 0
        for piece in pieces:
            spans.append((position, position + len(piece)))
            position += len(piece)
        spans_of.append(spans)
        records.append({'s': title, 'g': [[a, b, title[a:b], '', 0] for a, b in spans]})
    classed = run_segcli(segcli, db_path, ['count', lexical_path],
                         ''.join(json.dumps(r, ensure_ascii=False) + '\n' for r in records))
    tokens, skipped = [], 0
    for i, (row, spans, line) in enumerate(zip(rows, spans_of, classed)):
        if spans is None:
            skipped += 1
            continue
        title = titles[i]
        parsed = {(a, b): (name, lemma) for a, b, name, lemma in u.parse_tokens(line)}
        words = [parsed.get(span, (u.BOUNDARY, None)) for span in spans]
        window_words = [lemma or title[a:b] for (name, lemma), (a, b) in zip(words, spans)]
        position = 0
        for kanji, reading in row['pairs']:
            found = title.find(kanji, position)
            if found < 0:
                continue
            position = found + len(kanji)
            j = next((n for n, (a, b) in enumerate(spans) if a <= found < b), None)
            if j is None or spans[j][1] < found + len(kanji):
                continue
            runs = [m.group() for m in u.KANJI.finditer(title[spans[j][0]:spans[j][1]])]
            if runs != [kanji]:
                continue
            prev = words[j - 1] if j > 0 else (u.BOUNDARY, None)
            nxt = words[j + 1] if j + 1 < len(spans) else (u.BOUNDARY, None)
            tokens.append(dict(sid=10 ** 9 + i, k=kanji, r=u.to_hiragana(reading), cls=(prev[0], nxt[0]), words=(prev[1], nxt[1]),
                               num_before=False, num_after=False, gap_before=False, gap_after=False,
                               window=[(o, window_words[j + o]) for o in range(-WINDOW, WINDOW + 1)
                                       if o and 0 <= j + o < len(spans)]))
    pickle.dump(tokens, open(out_path, 'wb'))
    print(f'{len(titles)} titles ({skipped} unsegmentable), {len(tokens)} tokens')


if __name__ == '__main__':
    main(*sys.argv[1:9])
