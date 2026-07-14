#!/usr/bin/env python3
# Finds the chapter each currently-chapterless Resources/human-japanese.csv word first appears in,
# by searching the human-japanese project's own lesson html files (html/<volume>-<chapter>-*.html)
# for the word's literal text. The html filename's chapter number is confirmed (cross-checked
# against 白/しろ via the source hj.db's `entries` table) to match the SAME numbering our CSV's
# `chapter` column already uses — so a hit's filename gives the chapter directly, no ID math
# needed. Searches volume 1 files before volume 2 so a word taught in volume 1 but only listed
# chapterless under a volume-2 row still resolves to its true (earlier) first appearance.
#
# For a kanji-spelled word, searching the kanji surface directly only finds chapters AFTER kanji
# was introduced for that word — kanji comes late in the curriculum, so the word's true (earlier)
# first appearance is almost always in kana. So kanji words are searched by their dictionary
# READING (via Kioku's own dictionary.sqlite), not their kanji spelling; the kanji spelling is
# tried only as a fallback when no reading is resolvable or the reading search comes up empty.
#
# Usage:
#   .venv/bin/python3 scripts/find_chapters_in_lessons.py
import csv
import re
import sqlite3
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
CSV_PATH = PROJECT_ROOT / "Resources" / "human-japanese.csv"
DB_PATH = PROJECT_ROOT / "Resources" / "dictionary.sqlite"
HJ_ROOT = Path("/Users/matthewmorrone/Projects/human-japanese")
HTML_DIR = HJ_ROOT / "html"

FILENAME_RE = re.compile(r"^(\d)-(\d{2})-")


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


def ordered_html_files():
    files = []
    for path in HTML_DIR.glob("*.html"):
        m = FILENAME_RE.match(path.name)
        if not m:
            continue
        volume, chapter = int(m.group(1)), int(m.group(2))
        files.append((volume, chapter, path))
    files.sort(key=lambda t: (t[0], t[1]))
    return files


def main():
    with open(CSV_PATH, encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f)
        fieldnames = reader.fieldnames
        rows = list(reader)

    chapterless = [row for row in rows if not row["chapter"]]
    print(f"{len(chapterless)} chapterless rows to search for.")

    # Load every lesson file's text once, in (volume, chapter) order.
    files = ordered_html_files()
    contents = [(vol, ch, path.read_text(encoding="utf-8", errors="replace")) for vol, ch, path in files]
    print(f"Loaded {len(contents)} lesson files.")

    conn = sqlite3.connect(str(DB_PATH))

    def first_occurrence(text_to_find):
        for vol, ch, text in contents:
            if text_to_find in text:
                return (vol, ch)
        return None

    found = 0
    found_via_reading = 0
    still_missing = []
    for row in chapterless:
        word = row["word"]
        search_terms = []
        if contains_kanji(word):
            search_terms.extend(readings_for_kanji_surface(conn, word))
        search_terms.append(word)  # fallback: the literal (possibly kanji) surface itself

        hit = None
        used_reading = False
        for term in search_terms:
            hit = first_occurrence(term)
            if hit:
                used_reading = term != word
                break

        if hit:
            row["volume"], row["chapter"] = str(hit[0]), str(hit[1])
            found += 1
            if used_reading:
                found_via_reading += 1
        else:
            still_missing.append(word)

    conn.close()

    with open(CSV_PATH, "w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    print(f"Found a lesson occurrence for {found} words ({found_via_reading} via kana reading).")
    print(f"{len(still_missing)} words not found in any lesson file:")
    for word in still_missing:
        print(f"  {word}")


if __name__ == "__main__":
    main()
