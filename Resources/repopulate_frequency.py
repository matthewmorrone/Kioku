#!/usr/bin/env python3
# Frequency-only refresh of an already-built dictionary.sqlite.
#
# Re-scores every kanji/kana surface with wordfreq and rebuilds the two materialized
# frequency tables (surface_readings, word_frequency) — WITHOUT the full ~30-min rebuild
# (JMdict parse, MeCab context-ID harvest, FTS reindex). Use this when only wordfreq_zipf
# needs (re)populating, e.g. after `pip install wordfreq` on a DB that was built without it.
#
# Requires the wordfreq package:  pip install wordfreq mecab-python3 ipadic
# Run with the same interpreter the build uses:  .venv/bin/python3 Resources/repopulate_frequency.py
#
# The full builder (generate_db.py) calls the SAME import_wordfreq + materialize_* functions,
# so this produces byte-for-byte the frequency data a clean rebuild would.
import sqlite3
import sys
import time
from pathlib import Path

import generate_db as g

DB_PATH = Path(__file__).resolve().parent / "dictionary.sqlite"


def main():
    if not DB_PATH.exists():
        sys.exit(f"dictionary.sqlite not found at {DB_PATH} — run generate_db.py first")

    try:
        from wordfreq import zipf_frequency  # noqa: F401
    except ImportError:
        sys.exit("wordfreq not installed — run: pip install wordfreq mecab-python3 ipadic")

    start = time.time()
    conn = sqlite3.connect(str(DB_PATH))
    print(f"Refreshing frequency data in {DB_PATH.name}...")

    g.import_wordfreq(conn)
    g.materialize_surface_readings(conn)
    g.materialize_word_frequency(conn)

    conn.commit()
    conn.execute("ANALYZE")
    conn.execute("PRAGMA optimize")
    conn.close()
    print(f"Done in {time.time() - start:.1f}s")


if __name__ == "__main__":
    main()
