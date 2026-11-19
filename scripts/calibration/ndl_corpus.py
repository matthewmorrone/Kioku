"""National Diet Library bibliography furigana (ndl-lab/huriganacorpus-ndlbib, as the Furigana-NDLBIB dataset
on Hugging Face: ~16M titles with ruby-annotated readings) as extra training tokens for reading_model.

Tatoeba shows a reading too few times to model most ambiguous kanji runs; NDL shows them in book titles with a
reading marked on every kanji. The build streams the 14 Arrow shards (a shard is downloaded, read and deleted
before the next, so the 6.8 GB is never on disk), keeps up to CAP titles per (kanji, reading) drawn uniformly
over the whole set, segments them with the app's own segmenter, and turns each marked kanji run that is exactly
one segment's only kanji run into a token shaped like usage_tables'/reading_model's. Sentence ids start at
10**9 so they never collide with Tatoeba's. Only readings Tatoeba also lists for that kanji are kept.

  sample_titles(readings, urls, download, scratch)   the sampled titles and a digest of the shards read
  training_tokens(rows, segment, classify, lexical)  the tokens, one per usable ruby pair
"""
import collections
import hashlib
import heapq
import json
import os
import random
import re
from pathlib import Path

import usage_tables as u

CAP = 400
SEED = 7
SEPARATOR = '\x1e'
WINDOW = 5
FIRST_ID = 10 ** 9
RUBY = re.compile(r'<ruby>([^<]+)<rt>([^<]+)</rt></ruby>')


def ambiguous_readings(tokens):
    """{kanji run: its readings} for the runs Tatoeba reads two or more ways, the only runs the model uses."""
    readings = collections.defaultdict(set)
    for t in tokens:
        readings[t['k']].add(t['r'])
    return {k: rs for k, rs in readings.items() if len(rs) > 1}


def sample_titles(readings, urls, download, scratch):
    """(rows, digest, bytes read): the titles ([{'s': title, 'pairs': [[kanji, reading], ...]}, ...], digest) for up to CAP titles per (kanji, reading) of
    `readings`, uniform over every shard (random priorities, a bounded heap per key, so a reading with fewer than
    CAP examples keeps all of them). `download(url, path)` fetches a shard; the digest is the sha256 of the
    shards' own sha256 digests, in order, so a rebuild can tell whether upstream changed."""
    import pyarrow as pa
    rng = random.Random(SEED)
    heaps = collections.defaultdict(list)    # (kanji, reading) -> [(priority, title id)]
    titles = {}                              # title id -> (text, pairs)
    digests, size = [], 0
    next_id = 0
    for number, url in enumerate(urls, 1):
        path = Path(scratch) / f'ndl-{number:05d}.arrow'
        download(url, path)
        size += path.stat().st_size
        with open(path, 'rb') as shard:
            digests.append(hashlib.file_digest(shard, 'sha256').hexdigest())
        table = pa.ipc.open_stream(pa.memory_map(str(path))).read_all()
        for text, output in zip(table.column('input').to_pylist(), table.column('output').to_pylist()):
            pairs = RUBY.findall(output)
            wanted = {(k, r) for k, r in pairs if k in readings and r in readings[k]}
            if not wanted:
                continue
            priority, placed = rng.random(), False
            for key in sorted(wanted):
                heap = heaps[key]
                if len(heap) < CAP:
                    heapq.heappush(heap, (priority, next_id))
                    placed = True
                elif priority > heap[0][0]:
                    heapq.heapreplace(heap, (priority, next_id))
                    placed = True
            if placed:
                titles[next_id] = (text, pairs)
                next_id += 1
        print(f'  NDL shard {number}/{len(urls)}: {len(titles)} titles held, {len(heaps)} keys', flush=True)
        del table
        os.remove(path)
    keep = sorted({tid for heap in heaps.values() for _, tid in heap})
    rows = [{'s': titles[tid][0].replace('\n', ' '), 'pairs': titles[tid][1]} for tid in keep]
    return rows, hashlib.sha256(''.join(digests).encode()).hexdigest(), size


def training_tokens(rows, segment, classify, lexical):
    """One token dict per ruby pair whose kanji run is exactly one segment's only kanji run, with the segment's
    neighbours' classes and lemmas and the +-WINDOW lemma window, as reading_model.training_tokens makes them.
    `segment(titles)` returns the segmenter's output lines (segments joined by SEPARATOR), `classify(lexical,
    records)` the `segcli count` lines for gold records."""
    titles = [r['s'] for r in rows]
    lines = segment(titles)
    if len(lines) != len(titles):
        raise RuntimeError(f'segmenter returned {len(lines)} lines for {len(titles)} NDL titles')
    records, spans_of = [], []
    for title, line in zip(titles, lines):
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
    classed = classify(lexical, records)
    if len(classed) != len(records):
        raise RuntimeError(f'segcli count returned {len(classed)} lines for {len(records)} NDL titles')
    tokens = []
    for i, (row, spans, line) in enumerate(zip(rows, spans_of, classed)):
        if spans is None:
            continue
        title = titles[i]
        parsed = {(a, b): (name, lemma) for a, b, name, lemma in u.parse_tokens(line)}
        words = [parsed.get(span, (u.BOUNDARY, None)) for span in spans]
        window_words = [lemma or title[a:b] for (_, lemma), (a, b) in zip(words, spans)]
        position = 0
        for kanji, reading in row['pairs']:
            found = title.find(kanji, position)
            if found < 0:
                continue
            position = found + len(kanji)
            j = next((n for n, (a, b) in enumerate(spans) if a <= found < b), None)
            if j is None or spans[j][1] < found + len(kanji):
                continue
            if [m.group() for m in u.KANJI.finditer(title[spans[j][0]:spans[j][1]])] != [kanji]:
                continue
            prev = words[j - 1] if j > 0 else (u.BOUNDARY, None)
            nxt = words[j + 1] if j + 1 < len(spans) else (u.BOUNDARY, None)
            tokens.append(dict(sid=FIRST_ID + i, k=kanji, r=u.to_hiragana(reading), cls=(prev[0], nxt[0]),
                               words=(prev[1], nxt[1]), num_before=False, num_after=False, gap_before=False,
                               gap_after=False,
                               window=[(o, window_words[j + o]) for o in range(-WINDOW, WINDOW + 1)
                                       if o and 0 <= j + o < len(spans)]))
    return tokens
