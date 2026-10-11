#!/usr/bin/env python3
"""Builds the segmenter's class overrides (Kioku/Dictionary/Segmenter/segmenter-class-overrides.tsv).

The transition table classes a word by the POS bits of its spelling, and a spelling's bits are the
union of every entry and sense spelled that way, collapsed in TransitionClass's fixed order. That
order puts conjunction and adverb before noun, so 間 (あいだ: noun first, also adverb and the
conjunction "while") was classed conj, and 中日|間 lost to 中|日間. JMdict lists an entry's senses
most-used first, so the first sense of the spelling's most common entry says what the word usually
is. One row per kanji-bearing spelling whose first-sense POS differs from the union:
"surface <tab> pos codes". Kana spellings are left alone: a kana spelling is shared by unrelated
words (は 歯 葉 particle), and their frequency ranks don't say which one a text means.

    python3 segmenter_class_overrides.py ../../Resources/dictionary.sqlite > ../../Kioku/Dictionary/Segmenter/segmenter-class-overrides.tsv

Recount the transition table and the reading contexts after regenerating it: both count classes
the running code assigns. 2026-10-10: 3,915 spellings; with the table recounted, fresh5k
cut-throughs 69 → 66, held2k 61 → 62, kana2k 213 → 213, readings held2k 95.19% → 95.43%,
fresh5k 96.90% → 97.51%, lyrics 38/38, named cases 67/67.
"""
import collections, re, sqlite3, sys

KANJI = re.compile(r'[㐀-䶿一-鿿豈-﫿々]')


def main():
    db = sqlite3.connect(f'file:{sys.argv[1]}?mode=ro', uri=True)
    first_pos = {}
    for entry_id, pos in db.execute("""
            SELECT s.entry_id, s.pos FROM senses s
            JOIN (SELECT entry_id, MIN(order_index) AS o FROM senses GROUP BY entry_id) f
              ON f.entry_id = s.entry_id AND f.o = s.order_index"""):
        first_pos[entry_id] = set((pos or '').split(',')) - {''}
    all_pos = collections.defaultdict(set)
    for entry_id, pos in db.execute("SELECT entry_id, pos FROM senses"):
        all_pos[entry_id] |= set((pos or '').split(',')) - {''}
    rank_by_kanji_id = dict(db.execute("""
            SELECT kanji_id, MIN(frequency_rank) FROM word_frequency
            WHERE frequency_rank IS NOT NULL AND kanji_id IS NOT NULL GROUP BY kanji_id"""))
    entries_by_surface = collections.defaultdict(list)
    for kanji_id, text, entry_id in db.execute("SELECT id, text, entry_id FROM kanji"):
        entries_by_surface[text].append((rank_by_kanji_id.get(kanji_id), entry_id))
    for surface in sorted(entries_by_surface):
        if not KANJI.search(surface):
            continue
        rows = entries_by_surface[surface]
        ranked = [row for row in rows if row[0] is not None]
        if not ranked:
            continue
        primary = first_pos.get(min(ranked)[1], set())
        union = set().union(*(all_pos[entry_id] for _, entry_id in rows))
        if primary and primary != union:
            print(f"{surface}\t{','.join(sorted(primary))}")


if __name__ == '__main__':
    main()
