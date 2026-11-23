#!/usr/bin/env python3
"""Cuts a pretrained .vec(.gz) file (fastText cc.ja.300, CC BY-SA 3.0) down to the words the token cache
uses, so the 1.3 GB download can be deleted afterwards and nothing but a small float16 array is kept.

  python3 vectors.py <cc.ja.300.vec.gz> <tokens.pkl> <out.npz>

Streams the file line by line (never loaded whole). Prints how many of the cache's window words, by
occurrence, have a vector."""
import collections, gzip, pickle, sys
import numpy as np


def main(vec_path, tokens_path, out_path):
    """Writes out.npz with `words` and `vectors` (float16, L2-normalised) for every cache word found."""
    cache = pickle.load(open(tokens_path, 'rb'))
    occurrences = collections.Counter(w for t in cache['tokens'] for _, w in t['window'])
    words, rows = [], []
    with gzip.open(vec_path, 'rt', encoding='utf-8') as f:
        next(f)
        for line in f:
            word, _, rest = line.partition(' ')
            if word in occurrences:
                v = np.array(rest.split(), dtype=np.float32)
                words.append(word)
                rows.append((v / (np.linalg.norm(v) or 1.0)).astype(np.float16))
    np.savez(out_path, words=np.array(words), vectors=np.stack(rows))
    covered = sum(n for w, n in occurrences.items() if w in set(words))
    print(f'{len(words)} of {len(occurrences)} window words found; '
          f'{100 * covered / sum(occurrences.values()):.1f}% of window occurrences covered')


if __name__ == '__main__':
    main(*sys.argv[1:4])
