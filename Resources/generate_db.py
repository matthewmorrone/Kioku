import json
import sqlite3
import hashlib
from pathlib import Path
import sys
import time

PROJECT_ROOT = Path(__file__).resolve().parent.parent
RESOURCES_DIR = PROJECT_ROOT / "Resources"
JMDICT_PATH = RESOURCES_DIR / "jmdict-eng-3.6.2.json"
OUTPUT_DB = RESOURCES_DIR / "dictionary.sqlite"

def sha256_of_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


def ensure_input_exists():
    if not JMDICT_PATH.exists():
        print(f"Missing JMdict file at: {JMDICT_PATH}")
        sys.exit(1)


def create_schema(conn):
    conn.executescript(
        """
        PRAGMA foreign_keys = ON;

        CREATE TABLE entries (
            id INTEGER PRIMARY KEY,
            ent_seq INTEGER UNIQUE,
            priority TEXT,
            is_common INTEGER NOT NULL DEFAULT 0
        );

        CREATE TABLE kanji (
            text TEXT NOT NULL,
            entry_id INTEGER NOT NULL,
            FOREIGN KEY(entry_id) REFERENCES entries(id)
        );

        CREATE TABLE kana_forms (
            text TEXT NOT NULL,
            entry_id INTEGER NOT NULL,
            FOREIGN KEY(entry_id) REFERENCES entries(id)
        );

        CREATE TABLE senses (
            id INTEGER PRIMARY KEY,
            entry_id INTEGER NOT NULL,
            order_index INTEGER NOT NULL,
            pos TEXT,
            misc TEXT,
            field TEXT,
            dialect TEXT,
            FOREIGN KEY(entry_id) REFERENCES entries(id)
        );

        CREATE TABLE glosses (
            sense_id INTEGER NOT NULL,
            order_index INTEGER NOT NULL,
            gloss TEXT NOT NULL,
            FOREIGN KEY(sense_id) REFERENCES senses(id)
        );

        CREATE INDEX idx_kanji_text ON kanji(text);
        CREATE INDEX idx_kana_text ON kana_forms(text);
        CREATE INDEX idx_entries_ent_seq ON entries(ent_seq);
        """
    )


def build_database():
    if OUTPUT_DB.exists():
        OUTPUT_DB.unlink()

    conn = sqlite3.connect(OUTPUT_DB)
    create_schema(conn)

    with open(JMDICT_PATH, "r", encoding="utf-8") as f:
        data = json.load(f)

    if isinstance(data, list):
        entries = data
    elif isinstance(data, dict) and "words" in data:
        entries = data["words"]
    else:
        raise ValueError("Unexpected JMdict JSON structure")

    entry_insert = "INSERT INTO entries (ent_seq, priority, is_common) VALUES (?, ?, ?)"
    kanji_insert = "INSERT INTO kanji (text, entry_id) VALUES (?, ?)"
    kana_insert  = "INSERT INTO kana_forms (text, entry_id) VALUES (?, ?)"
    sense_insert = "INSERT INTO senses (entry_id, order_index, pos, misc, field, dialect) VALUES (?, ?, ?, ?, ?, ?)"
    gloss_insert = "INSERT INTO glosses (sense_id, order_index, gloss) VALUES (?, ?, ?)"

    for entry in entries:
        ent_seq = int(entry.get("id"))

        # Extract priority markers from kanji/kana forms
        priorities = []
        for k in entry.get("kanji", []):
            for p in k.get("priority", []) or []:
                priorities.append(p)
        for r in entry.get("kana", []):
            for p in r.get("priority", []) or []:
                priorities.append(p)

        priority_str = ",".join(sorted(set(priorities))) if priorities else None

        # Common heuristic: JMdict "news", "ichi", or "spec" markers imply common
        is_common = 1 if any(
            p.startswith(("news", "ichi", "spec"))
            for p in priorities
        ) else 0

        cur = conn.execute(entry_insert, (ent_seq, priority_str, is_common))
        entry_id = cur.lastrowid

        for k in entry.get("kanji", []):
            conn.execute(kanji_insert, (k["text"], entry_id))

        for r in entry.get("kana", []):
            conn.execute(kana_insert, (r["text"], entry_id))

        for s_idx, sense in enumerate(entry.get("sense", [])):
            pos = ",".join(sense.get("partOfSpeech", []) or []) if sense.get("partOfSpeech") else None
            misc = ",".join(sense.get("misc", []) or []) if sense.get("misc") else None
            field = ",".join(sense.get("field", []) or []) if sense.get("field") else None
            dialect = ",".join(sense.get("dialect", []) or []) if sense.get("dialect") else None

            cur = conn.execute(
                sense_insert,
                (entry_id, s_idx, pos, misc, field, dialect)
            )
            sense_id = cur.lastrowid

            for g_idx, gloss in enumerate(sense.get("gloss", [])):
                if isinstance(gloss, dict):
                    conn.execute(gloss_insert, (sense_id, g_idx, gloss.get("text", "")))
                else:
                    conn.execute(gloss_insert, (sense_id, g_idx, gloss))

    conn.commit()
    conn.close()


def main():
    start = time.time()
    ensure_input_exists()

    print("Building dictionary.sqlite...")
    print(f"JMdict SHA256: {sha256_of_file(JMDICT_PATH)}")

    build_database()

    print(f"Done in {time.time() - start:.2f}s")
    print(f"Output: {OUTPUT_DB}")


if __name__ == "__main__":
    main()