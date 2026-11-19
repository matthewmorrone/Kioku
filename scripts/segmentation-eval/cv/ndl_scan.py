#!/usr/bin/env python3
"""How much does the NDL bibliography furigana data add for the readings Tatoeba rarely shows?
Parses the <ruby> pairs of NDL Arrow shards (kanji run, reading) and counts, against Tatoeba's counted
readings (tokens.pkl): pairs on kanji Tatoeba has with 2+ readings, and how many of those are readings
Tatoeba saw fewer than RARE times. Needs pyarrow (run it from a throwaway venv).

  python ndl_scan.py <tokens.pkl> <shard.arrow>..."""
import collections, pickle, re, sys
import pyarrow as pa

RARE = 20
RUBY = re.compile(r'<ruby>([^<]+)<rt>([^<]+)</rt></ruby>')


def pairs(output):
    """The (kanji run, reading) pairs of one ruby-annotated title."""
    return RUBY.findall(output)


def main(tokens_path, shards):
    """Prints, per shard and in total, the pairs available to enrich rare readings."""
    tatoeba = collections.Counter((t['k'], t['r']) for t in pickle.load(open(tokens_path, 'rb'))['tokens'])
    readings = collections.defaultdict(set)
    for k, r in tatoeba:
        readings[k].add(r)
    ambiguous = {k for k, rs in readings.items() if len(rs) > 1}
    total, hit, rare_pairs, rare_titles, gained = 0, 0, 0, 0, collections.Counter()
    for path in shards:
        t = pa.ipc.open_stream(pa.memory_map(path)).read_all()
        for output in t.column('output').to_pylist():
            rare_here = False
            for kanji, reading in pairs(output):
                total += 1
                if kanji in ambiguous:
                    hit += 1
                    if tatoeba[(kanji, reading)] < RARE and reading in readings[kanji]:
                        rare_pairs += 1
                        rare_here = True
                        gained[(kanji, reading)] += 1
            rare_titles += rare_here
        print(f'{path.split("/")[-1]}: {t.num_rows} titles', flush=True)
    print(f'{total} ruby pairs; {hit} on Tatoeba-ambiguous kanji ({len(ambiguous)} kanji); '
          f'{rare_pairs} of those are readings Tatoeba saw < {RARE} times, in {rare_titles} titles')
    rare_keys = [(k, r) for (k, r), n in tatoeba.items() if n < RARE and k in ambiguous]
    print(f'{len(rare_keys)} rare (kanji, reading) keys in Tatoeba; NDL gives {sum(1 for key in rare_keys if gained[key] >= RARE)} of them 20+ examples '
          f'and {sum(1 for key in rare_keys if gained[key] > 0)} at least one')


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2:])
