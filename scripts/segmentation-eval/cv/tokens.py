#!/usr/bin/env python3
"""Builds the cross-validation's token cache: every counted gold reading of Tatoeba's indices, as
the dictionary build counts them (scripts/calibration/usage_tables.py), with the neighbour classes and
lemmas the app's ReadingContextTable keys on, the sentence id, and a +-WINDOW lemma window for the
embedding test. Gold segmentation, so this measures reading choice alone.

  python3 tokens.py <jpn_indices.csv> <dictionary.sqlite> <segcli> <work dir>

Writes <work dir>/tokens.pkl and <work dir>/lexical.txt. Run one segcli at a time (shared UserDefaults)."""
import collections, json, math, os, pickle, sqlite3, subprocess, sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'scripts' / 'calibration'))
import usage_tables as u
from reading_model import training_tokens


def classify(segcli, db_path, lexical_path, records):
    """One `segcli count` line per record, exactly as generate_db.py's classify does."""
    data = ''.join(json.dumps(r, ensure_ascii=False) + '\n' for r in records)
    p = subprocess.run([segcli, 'count', lexical_path], input=data, capture_output=True, text=True,
                       env=dict(os.environ, DB=db_path, SWIFT_DETERMINISTIC_HASHING='1'))
    if p.returncode != 0:
        raise RuntimeError(p.stderr[-2000:])
    return p.stdout.splitlines()


def main(index_path, db_path, segcli, out):
    """Builds and pickles the cache; prints how many tokens, ambiguous ones, and flagged ones there are."""
    os.makedirs(out, exist_ok=True)
    db = sqlite3.connect(db_path)
    spellings = {(s, u.to_hiragana(r)) for s, r in db.execute('SELECT surface, reading FROM surface_readings')}
    irregular = {t for (t,) in db.execute("SELECT DISTINCT k.text FROM kanji k JOIN senses s ON s.entry_id = k.entry_id "
                                          "WHERE ',' || s.pos || ',' LIKE '%,vk,%' OR ',' || s.pos || ',' LIKE '%,adj-ix,%'")}
    sentences = {str(a): b for a, b in db.execute('SELECT DISTINCT ja_id, japanese FROM sentence_pairs')}
    gold = list(u.gold_sentences(open(index_path, encoding='utf-8-sig'), sentences))
    counted, for_t = u.corpora(gold, REPO / 'scripts' / 'segmentation-eval' / 'data')
    lexical_path = os.path.join(out, 'lexical.txt')
    open(lexical_path, 'w').write('\n'.join(u.lexical_words([r for r, t in zip(counted, for_t) if t])) + '\n')
    order = sorted(range(len(counted)), key=lambda i: int(counted[i]['id']))
    counted = [counted[i] for i in order]
    lines = classify(segcli, db_path, lexical_path, counted)
    tokens = list(training_tokens(counted, lines, irregular, spellings))
    kana = list(training_tokens(counted, lines, irregular, spellings, kana=True))
    # Inverse document frequency of every window word over the counted sentences: weights content words up.
    df = collections.Counter()
    for record, line in zip(counted, lines):
        df.update({lemma or record['s'][a:b] for a, b, name, lemma in u.parse_tokens(line)})
    idf = {w: math.log(len(counted) / (n + 1)) for w, n in df.items()}
    pickle.dump(dict(tokens=tokens, kana=kana, idf=idf, sentences=len(counted)), open(os.path.join(out, 'tokens.pkl'), 'wb'))
    print(f'{len(kana)} kana-written tokens')
    print(f'{len(counted)} sentences, {len(tokens)} counted readings, '
          f'{sum(t["num_before"] for t in tokens)} with a numeral gap before, '
          f'{sum(t["gap_before"] for t in tokens)} with any gap before')


if __name__ == '__main__':
    main(*sys.argv[1:5])
