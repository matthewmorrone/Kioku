#!/usr/bin/env python3
# One-off data cleanup for Resources/human-japanese.csv: fills in the `chapter` column for rows
# whose word is a kanji spelling with no chapter of its own, by matching it (via dictionary.sqlite)
# to another row in the SAME file whose word is the plain-kana spelling of that reading and DOES
# have a chapter. This is the "you already learned this word in kana, here's its kanji form"
# pattern the Human Japanese textbook uses — the kanji-form row inherits the ORIGINAL chapter and
# volume it was actually taught in, not the volume the kanji reference happened to appear in.
#
# Usage:
#   .venv/bin/python3 scripts/backfill_human_japanese_chapters.py
import csv
import sqlite3
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
CSV_PATH = PROJECT_ROOT / "Resources" / "human-japanese.csv"
DB_PATH = PROJECT_ROOT / "Resources" / "dictionary.sqlite"


def is_kana_only(text):
    if not text:
        return False
    return all(
        0x3040 <= ord(ch) <= 0x309F  # hiragana
        or 0x30A0 <= ord(ch) <= 0x30FF  # katakana
        or 0xFF66 <= ord(ch) <= 0xFF9F  # halfwidth katakana
        for ch in text
    )


def contains_kanji(text):
    return any(0x4E00 <= ord(ch) <= 0x9FFF for ch in text)


def readings_for_kanji_surface(conn, surface):
    entry_ids = [row[0] for row in conn.execute("SELECT entry_id FROM kanji WHERE text = ?", (surface,))]
    if not entry_ids:
        return []
    placeholders = ",".join("?" * len(entry_ids))
    rows = conn.execute(
        f"SELECT DISTINCT text FROM kana_forms WHERE entry_id IN ({placeholders})", entry_ids
    )
    return [r[0] for r in rows]


# Godan ます-stems end in an い-row kana; the dictionary form swaps it for the matching う-row kana.
# e.g. 住みます -> stem 住み -> 住む. Ichidan stems don't fit this pattern (their final kana isn't
# い-row at all, e.g. 食べ from 食べます), so they're covered separately by the plain stem+る guess.
_GODAN_I_TO_U = {
    "い": "う", "き": "く", "ぎ": "ぐ", "し": "す", "ち": "つ",
    "に": "ぬ", "び": "ぶ", "み": "む", "り": "る",
}
_MASU_SUFFIXES = ["ませんでした", "ました", "ません", "ます"]


# Guesses dictionary-form candidates for a ます-conjugated surface, ichidan first (unambiguous
# stem+る) then a godan candidate when the stem's final kana fits the い-row pattern. Not a full
# deinflector (no irregular する/来る handling, no other conjugation families) — narrow and
# specific to backfilling this one dataset's masu-form rows against their own kana-form siblings.
def masu_form_candidates(word):
    for suffix in _MASU_SUFFIXES:
        if word.endswith(suffix):
            stem = word[: -len(suffix)]
            if not stem:
                return []
            candidates = [stem + "る"]
            last = stem[-1]
            if last in _GODAN_I_TO_U:
                candidates.append(stem[:-1] + _GODAN_I_TO_U[last])
            return candidates
    return []


# A candidate surface's chapter/volume, if resolvable: check it directly against the kana map
# when it's pure kana, otherwise resolve its dictionary reading(s) first.
def lookup_candidate(conn, surface, kana_to_chapter_volume):
    if is_kana_only(surface):
        return kana_to_chapter_volume.get(surface)
    for reading in readings_for_kanji_surface(conn, surface):
        if reading in kana_to_chapter_volume:
            return kana_to_chapter_volume[reading]
    return None


def main():
    with open(CSV_PATH, encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f)
        fieldnames = reader.fieldnames
        rows = list(reader)

    kana_to_chapter_volume = {}
    for row in rows:
        if row["chapter"] and is_kana_only(row["word"]):
            kana_to_chapter_volume[row["word"]] = (row["chapter"], row["volume"])

    conn = sqlite3.connect(str(DB_PATH))
    filled = 0
    filled_via_masu = 0
    unmatched = []
    for row in rows:
        if row["chapter"] or not contains_kanji(row["word"]):
            continue

        match = lookup_candidate(conn, row["word"], kana_to_chapter_volume)
        via_masu = False
        if match is None:
            for candidate in masu_form_candidates(row["word"]):
                match = lookup_candidate(conn, candidate, kana_to_chapter_volume)
                if match is not None:
                    via_masu = True
                    break

        if match:
            row["chapter"], row["volume"] = match
            filled += 1
            if via_masu:
                filled_via_masu += 1
        else:
            unmatched.append(row["word"])
    conn.close()

    with open(CSV_PATH, "w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    print(f"Filled chapter for {filled} kanji rows ({filled_via_masu} via ます-form deinflection).")
    print(f"{len(unmatched)} kanji rows still have no chapter (no kana match found):")
    for word in unmatched:
        print(f"  {word}")


if __name__ == "__main__":
    main()
