#!/usr/bin/env python3
"""
One-shot migration: add ipadic_left_id / ipadic_right_id columns to kanji and
kana_forms in the existing dictionary.sqlite, then populate them via the mecab CLI.

The full generate_db.py pipeline includes this same step (see import_mecab_context_ids),
but running it standalone against the already-built dictionary is much faster than
regenerating the whole DB. Run again whenever IPADic changes or surfaces are added.

Usage:
    python3 Resources/migrate_add_context_ids.py
"""

from __future__ import annotations

import shutil
import sqlite3
import subprocess
import sys
from pathlib import Path

DB_PATH = Path(__file__).resolve().parent / "dictionary.sqlite"


def column_exists(conn: sqlite3.Connection, table: str, column: str) -> bool:
    cur = conn.execute(f"PRAGMA table_info({table})")
    return any(row[1] == column for row in cur.fetchall())


def ensure_columns(conn: sqlite3.Connection) -> None:
    for table in ("kanji", "kana_forms"):
        if not column_exists(conn, table, "ipadic_left_id"):
            print(f"  Adding {table}.ipadic_left_id")
            conn.execute(f"ALTER TABLE {table} ADD COLUMN ipadic_left_id INTEGER")
        if not column_exists(conn, table, "ipadic_right_id"):
            print(f"  Adding {table}.ipadic_right_id")
            conn.execute(f"ALTER TABLE {table} ADD COLUMN ipadic_right_id INTEGER")
    conn.commit()


def harvest_context_ids(conn: sqlite3.Connection) -> None:
    mecab_path = shutil.which("mecab")
    if mecab_path is None:
        sys.exit("mecab CLI not on PATH; install via 'brew install mecab mecab-ipadic'")

    cur = conn.execute("SELECT DISTINCT text FROM kanji UNION SELECT DISTINCT text FROM kana_forms")
    surfaces = [row[0] for row in cur.fetchall() if row[0]]

    if not surfaces:
        print("  No surfaces to tag")
        return

    print(f"  Tokenizing {len(surfaces)} distinct surfaces via mecab...")

    sanitized = [s.replace("\n", "").replace("\r", "").replace("\t", "") for s in surfaces]

    proc = subprocess.run(
        [
            mecab_path,
            "--node-format=%phl\t%phr\n",
            "--unk-format=%phl\t%phr\n",
            "--eos-format=__EOS__\n",
        ],
        input="\n".join(sanitized) + "\n",
        capture_output=True,
        text=True,
        check=True,
    )

    surface_to_ids: dict[str, tuple[int, int]] = {}
    current_first: int | None = None
    current_last: int | None = None
    surface_index = 0

    for line in proc.stdout.splitlines():
        if line == "__EOS__":
            if surface_index < len(surfaces) and current_first is not None and current_last is not None:
                surface_to_ids[surfaces[surface_index]] = (current_first, current_last)
            surface_index += 1
            current_first = None
            current_last = None
            continue
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        try:
            left_id = int(parts[0])
            right_id = int(parts[1])
        except ValueError:
            continue
        if current_first is None:
            current_first = left_id
        current_last = right_id

    print(f"  Parsed IDs for {len(surface_to_ids)} surfaces; updating SQLite...")

    updated_kanji = 0
    updated_kana = 0
    for surface, (left_id, right_id) in surface_to_ids.items():
        result = conn.execute(
            "UPDATE kanji SET ipadic_left_id = ?, ipadic_right_id = ? WHERE text = ?",
            (left_id, right_id, surface),
        )
        updated_kanji += result.rowcount
        result = conn.execute(
            "UPDATE kana_forms SET ipadic_left_id = ?, ipadic_right_id = ? WHERE text = ?",
            (left_id, right_id, surface),
        )
        updated_kana += result.rowcount

    conn.commit()
    print(f"  Tagged {updated_kanji} kanji rows + {updated_kana} kana rows")


def main() -> None:
    if not DB_PATH.exists():
        sys.exit(f"dictionary.sqlite not found at {DB_PATH}")

    conn = sqlite3.connect(DB_PATH)
    try:
        ensure_columns(conn)
        harvest_context_ids(conn)
    finally:
        conn.close()

    print("Done.")


if __name__ == "__main__":
    main()
