#!/usr/bin/env python3
"""Samples the NDL bibliography furigana data (Furigana-NDLBIB, CC BY 4.0, 14 Arrow shards of ~500 MB) down
to titles that carry labelled readings for the kanji Tatoeba sees with 2+ readings: up to CAP titles per
(kanji, reading), drawn uniformly over the WHOLE dataset (random priorities, a bounded heap per key), so a
reading with fewer than CAP examples keeps all of them. A shard is downloaded, read and deleted before the
next, so the full 6.8 GB is never on disk. Only readings Tatoeba also lists for that kanji are kept.
Needs pyarrow (run it from a throwaway venv).

  python ndl_extract.py <tokens.pkl> <shard dir> <out.jsonl>

Writes one JSON object per kept title: {"s": title, "pairs": [[kanji, reading], ...all ruby pairs...]}."""
import collections, heapq, json, os, pickle, random, re, subprocess, sys
import pyarrow as pa

CAP = 400
SHARDS = 14
URL = 'https://huggingface.co/datasets/Calvin-Xu/Furigana-NDLBIB/resolve/main/data-{:05d}-of-00014.arrow'
RUBY = re.compile(r'<ruby>([^<]+)<rt>([^<]+)</rt></ruby>')


def fetch(directory, n):
    """Path of shard n, downloading it (resumable, retried) unless it is already there."""
    path = os.path.join(directory, f'data-{n:05d}-of-00014.arrow')
    if not os.path.exists(path):
        subprocess.run(['curl', '-fSL', '--retry', '5', '--retry-delay', '5', '-C', '-', '-o', path + '.part', URL.format(n)], check=True)
        os.rename(path + '.part', path)
    return path


def main(tokens_path, directory, out_path):
    """Streams every shard through the per-key reservoirs and writes the kept titles."""
    random.seed(7)
    readings = collections.defaultdict(set)
    for t in pickle.load(open(tokens_path, 'rb'))['tokens']:
        readings[t['k']].add(t['r'])
    readings = {k: rs for k, rs in readings.items() if len(rs) > 1}
    heaps = collections.defaultdict(list)    # (kanji, reading) -> [(priority, title id)]
    titles = {}                              # title id -> (text, pairs)
    next_id = 0
    for n in range(SHARDS):
        path = fetch(directory, n)
        table = pa.ipc.open_stream(pa.memory_map(path)).read_all()
        for text, output in zip(table.column('input').to_pylist(), table.column('output').to_pylist()):
            pairs = RUBY.findall(output)
            wanted = [(k, r) for k, r in pairs if k in readings and r in readings[k]]
            if not wanted:
                continue
            priority, tid, placed = random.random(), next_id, False
            for key in set(wanted):
                heap = heaps[key]
                if len(heap) < CAP:
                    heapq.heappush(heap, (priority, tid))
                    placed = True
                elif priority > heap[0][0]:
                    heapq.heapreplace(heap, (priority, tid))
                    placed = True
            if placed:
                titles[tid] = (text, pairs)
                next_id += 1
        print(f'shard {n + 1}/{SHARDS}: {len(titles)} titles held, {len(heaps)} keys', flush=True)
        del table
        os.remove(path)
    keep = {tid for heap in heaps.values() for _, tid in heap}
    with open(out_path, 'w', encoding='utf-8') as f:
        for tid in sorted(keep):
            text, pairs = titles[tid]
            f.write(json.dumps({'s': text, 'pairs': pairs}, ensure_ascii=False) + '\n')
    sizes = collections.Counter(len(h) for h in heaps.values())
    print(f'{len(keep)} titles kept; keys by examples: ' + ', '.join(f'{lo}+ {sum(v for s, v in sizes.items() if s >= lo)}' for lo in (1, 20, 100, CAP)))


if __name__ == '__main__':
    main(*sys.argv[1:4])
