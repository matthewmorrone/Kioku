#!/usr/bin/env python3
"""Builds the segmenter's class overrides (Kioku/Dictionary/Segmenter/segmenter-class-overrides.tsv).

The transition table classes a word by the POS bits of its spelling, and a spelling's bits are the
union of every entry and sense spelled that way, collapsed in TransitionClass's fixed order, which
checks conjunction and adverb before noun: 間 (あいだ: noun, also adverb and the conjunction
"while") came out conj, and 中日|間 lost to 中|日間. The override gives a spelling the bits of the
word it usually is, from two sources in order:

  1. usage: Tatoeba's index marks which dictionary word every token is, by its JMdict headword
     (間 → 間(あいだ), は → the particle, whose headword is は; 歯 "tooth" is indexed as 歯), so a
     spelling seen at least MIN_TOKENS times written as itself takes the first sense of the entry
     it most often is. Kana and kanji alike.
  2. the dictionary, for spellings usage doesn't cover: a kanji spelling takes the first sense of
     its best-ranked entry (word_frequency). A kana spelling keeps the union, because its ranks
     belong to unrelated kanji words that share the kana (は → 歯 葉 刃).

One row per spelling whose bits differ from the union: "surface <tab> pos codes".

    python3 segmenter_class_overrides.py ../../Resources/dictionary.sqlite train-fit.jsonl \\
        > ../../Kioku/Dictionary/Segmenter/segmenter-class-overrides.tsv

train-fit.jsonl is the transition table's own input (prep.py's train.jsonl minus its first 2,000
lines), so no eval sentence shapes a class. Recount the transition table and the reading contexts
after regenerating: both count the classes the running code assigns.
"""
import collections, json, re, sqlite3, sys

KANJI = re.compile(r'[㐀-䶿一-鿿豈-﫿々]')
MIN_TOKENS = 3


def main():
    db = sqlite3.connect(f'file:{sys.argv[1]}?mode=ro', uri=True)
    first_pos = {}
    for entry_id, pos in db.execute("""
            SELECT s.entry_id, s.pos FROM senses s
            JOIN (SELECT entry_id, MIN(order_index) AS o FROM senses GROUP BY entry_id) f
              ON f.entry_id = s.entry_id AND f.o = s.order_index"""):
        first_pos[entry_id] = frozenset((pos or '').split(',')) - {''}
    all_pos = collections.defaultdict(set)
    for entry_id, pos in db.execute("SELECT entry_id, pos FROM senses"):
        all_pos[entry_id] |= set((pos or '').split(',')) - {''}
    rank_by_kanji_id = dict(db.execute("""
            SELECT kanji_id, MIN(frequency_rank) FROM word_frequency
            WHERE frequency_rank IS NOT NULL AND kanji_id IS NOT NULL GROUP BY kanji_id"""))
    entry_rank = dict(db.execute("""
            SELECT entry_id, MIN(frequency_rank) FROM word_frequency
            WHERE frequency_rank IS NOT NULL GROUP BY entry_id"""))
    entries_by_spelling = collections.defaultdict(set)
    ranked_kanji = collections.defaultdict(list)
    for kanji_id, text, entry_id in db.execute("SELECT id, text, entry_id FROM kanji"):
        entries_by_spelling[text].add(entry_id)
        ranked_kanji[text].append((rank_by_kanji_id.get(kanji_id), entry_id))
    readings_by_entry = collections.defaultdict(set)
    for text, entry_id in db.execute("SELECT text, entry_id FROM kana_forms"):
        entries_by_spelling[text].add(entry_id)
        readings_by_entry[entry_id].add(text)
    # Each entry's JMdict headword: its first kanji spelling, or its first kana one when it has
    # none. Tatoeba's index names words by this headword, so 歯 "tooth" is indexed as 歯 and a
    # token indexed as は is an entry whose headword is は (the particle).
    entries_by_headword = collections.defaultdict(set)
    first_kanji = dict(db.execute("SELECT entry_id, text FROM kanji WHERE id IN (SELECT MIN(id) FROM kanji GROUP BY entry_id)"))
    first_kana = dict(db.execute("SELECT entry_id, text FROM kana_forms WHERE id IN (SELECT MIN(id) FROM kana_forms GROUP BY entry_id)"))
    for entry_id in set(first_kanji) | set(first_kana):
        entries_by_headword[first_kanji.get(entry_id) or first_kana[entry_id]].add(entry_id)

    # Usage: for each spelling written as itself in the gold, which entry it was each time.
    used_as = collections.defaultdict(collections.Counter)
    for line in open(sys.argv[2]):
        record = json.loads(line)
        for start, end, headword, reading, *_ in record['g']:
            surface = record['s'][start:end]
            if surface != headword or surface not in entries_by_headword:
                continue
            entries = entries_by_headword[surface]
            if reading and not reading.startswith('#'):
                entries = {e for e in entries if reading in readings_by_entry[e]} or entries
            # Several entries still fit (homographs the index doesn't separate): the best-ranked one.
            entry = min(entries, key=lambda e: (entry_rank.get(e, 10**9), e))
            used_as[surface][entry] += 1

    for surface in sorted(entries_by_spelling):
        union = set().union(*(all_pos[e] for e in entries_by_spelling[surface]))
        usage = used_as.get(surface)
        if usage and sum(usage.values()) >= MIN_TOKENS:
            primary = first_pos.get(usage.most_common(1)[0][0], frozenset())
        elif KANJI.search(surface):
            ranked = [row for row in ranked_kanji[surface] if row[0] is not None]
            if not ranked:
                continue
            primary = first_pos.get(min(ranked)[1], frozenset())
        else:
            continue
        if primary and set(primary) != union:
            print(f"{surface}\t{','.join(sorted(primary))}")


if __name__ == '__main__':
    main()
