import json
import sqlite3
import hashlib
from pathlib import Path
import sys
import time

PROJECT_ROOT = Path(__file__).resolve().parent.parent
RESOURCES_DIR = PROJECT_ROOT / "Resources"
JMDICT_PATH = RESOURCES_DIR / "jmdict-eng-3.6.2.json"
EXTRAS_PATH = RESOURCES_DIR / "extras.json"
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
            id INTEGER PRIMARY KEY,
            text TEXT NOT NULL,
            entry_id INTEGER NOT NULL,
            priority TEXT,
            FOREIGN KEY(entry_id) REFERENCES entries(id)
        );

        CREATE TABLE kana_forms (
            id INTEGER PRIMARY KEY,
            text TEXT NOT NULL,
            entry_id INTEGER NOT NULL,
            priority TEXT,
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
            id INTEGER PRIMARY KEY,
            sense_id INTEGER NOT NULL,
            order_index INTEGER NOT NULL,
            gloss TEXT NOT NULL,
            FOREIGN KEY(sense_id) REFERENCES senses(id)
        );

        CREATE TABLE surface_lookup (
            surface TEXT NOT NULL,
            entry_id INTEGER NOT NULL,
            FOREIGN KEY(entry_id) REFERENCES entries(id)
        );

        CREATE INDEX idx_kanji_text ON kanji(text);
        CREATE INDEX idx_kana_text ON kana_forms(text);
        CREATE INDEX idx_entries_ent_seq ON entries(ent_seq);
        CREATE INDEX idx_kanji_entry_id ON kanji(entry_id);
        CREATE INDEX idx_kana_entry_id ON kana_forms(entry_id);
        CREATE INDEX idx_senses_entry_id ON senses(entry_id);
        CREATE INDEX idx_glosses_sense_id ON glosses(sense_id);
        CREATE INDEX idx_surface_lookup_surface ON surface_lookup(surface);
        """
    )


def load_jmdict_entries():
    with open(JMDICT_PATH, "r", encoding="utf-8") as f:
        data = json.load(f)

    if isinstance(data, list):
        return data
    if isinstance(data, dict) and "words" in data:
        return data["words"]

    raise ValueError("Unexpected JMdict JSON structure")


def load_extra_entries():
    # [
    #   {
    #     ent_seq?: integer,
    #     is_common?: 0 | 1,
    #     priority?: [string],
    #     kanji?: [ string |
    #       {
    #         text: string,
    #         priority?: [string]
    #       }
    #     ],
    #     kana?: [ string |
    #       {
    #         text: string,
    #         priority?: [string]
    #       }
    #     ],
    #     senses?: [
    #       {
    #         partOfSpeech?: [string],
    #         misc?: [string],
    #         field?: [string],
    #         dialect?: [string],
    #         gloss?: [ string |
    #           {
    #             text: string
    #           }
    #         ]
    #       }
    #     ],
    #     gloss?: string | { text: string } | [ string | { text: string } ]
    #       # shorthand allowed only when senses is omitted;
    #       # normalizes to senses: [{ gloss: [...] }]
    #   }
    # ]
    if not EXTRAS_PATH.exists():
        return []

    with open(EXTRAS_PATH, "r", encoding="utf-8") as f:
        data = json.load(f)

    if isinstance(data, list):
        return [normalize_extra_entry(entry, entry_index) for entry_index, entry in enumerate(data)]

    raise ValueError("Unexpected extras JSON structure")


def normalize_extra_entry(entry, entry_index):
    if not isinstance(entry, dict):
        raise ValueError(f"extras.json entry {entry_index} must be an object")

    normalized_entry = dict(entry)

    for form_key in ("kanji", "kana"):
        form_value = normalized_entry.get(form_key)
        if isinstance(form_value, str):
            normalized_entry[form_key] = [form_value]
        elif form_value is not None and not isinstance(form_value, list):
            raise ValueError(f"extras.json entry {entry_index} field '{form_key}' must be a string or array")

    shorthand_gloss = normalized_entry.pop("gloss", None)
    existing_senses = normalized_entry.get("senses")

    if shorthand_gloss is not None and existing_senses is not None:
        raise ValueError(
            f"extras.json entry {entry_index} cannot specify both 'gloss' shorthand and 'senses'"
        )

    if isinstance(existing_senses, str):
        normalized_entry["senses"] = [{"gloss": [existing_senses]}]
    elif isinstance(existing_senses, dict):
        normalized_entry["senses"] = [existing_senses]
    elif existing_senses is not None and not isinstance(existing_senses, list):
        raise ValueError(f"extras.json entry {entry_index} field 'senses' must be a string, object, or array")

    if shorthand_gloss is not None:
        if isinstance(shorthand_gloss, list):
            gloss_list = shorthand_gloss
        else:
            gloss_list = [shorthand_gloss]

        normalized_entry["senses"] = [{"gloss": gloss_list}]

    return normalized_entry


def insert_entry(conn, entry_insert, kanji_insert, kana_insert, sense_insert, gloss_insert, entry, ent_seq):
    priorities = []
    for k in entry.get("kanji", []):
        if isinstance(k, str):
            continue
        for p in k.get("priority", []) or []:
            priorities.append(p)
    for r in entry.get("kana", []):
        if isinstance(r, str):
            continue
        for p in r.get("priority", []) or []:
            priorities.append(p)

    priority_str = ",".join(sorted(set(priorities))) if priorities else None
    is_common = 1 if any(
        p.startswith(("news", "ichi", "spec", "custom"))
        for p in priorities
    ) else int(entry.get("is_common", 0))

    cur = conn.execute(entry_insert, (ent_seq, priority_str, is_common))
    entry_id = cur.lastrowid
    surface_insert = "INSERT INTO surface_lookup (surface, entry_id) VALUES (?, ?)"

    for k in entry.get("kanji", []):
        if isinstance(k, str):
            conn.execute(kanji_insert, (k, entry_id, None))
            conn.execute(surface_insert, (k, entry_id))
            continue

        k_priorities = ",".join(sorted(set(k.get("priority", []) or []))) if k.get("priority") else None
        conn.execute(kanji_insert, (k["text"], entry_id, k_priorities))
        conn.execute(surface_insert, (k["text"], entry_id))

    for r in entry.get("kana", []):
        if isinstance(r, str):
            conn.execute(kana_insert, (r, entry_id, None))
            conn.execute(surface_insert, (r, entry_id))
            continue

        r_priorities = ",".join(sorted(set(r.get("priority", []) or []))) if r.get("priority") else None
        conn.execute(kana_insert, (r["text"], entry_id, r_priorities))
        conn.execute(surface_insert, (r["text"], entry_id))

    for s_idx, sense in enumerate(entry.get("senses", [])):
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


def resolve_extra_ent_seq(entry, entry_index, used_ent_seqs, next_custom_ent_seq):
    explicit_ent_seq = entry.get("ent_seq")
    if explicit_ent_seq is not None:
        ent_seq = int(explicit_ent_seq)
        if ent_seq in used_ent_seqs:
            raise ValueError(
                f"extras.json entry {entry_index} specifies ent_seq {ent_seq}, but that ent_seq is already in use"
            )
        return ent_seq, next_custom_ent_seq

    ent_seq = next_custom_ent_seq
    while ent_seq in used_ent_seqs:
        ent_seq -= 1

    return ent_seq, ent_seq - 1


def build_database():
    if OUTPUT_DB.exists():
        OUTPUT_DB.unlink()

    conn = sqlite3.connect(OUTPUT_DB)
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("BEGIN")
    create_schema(conn)

    entries = load_jmdict_entries()
    extra_entries = load_extra_entries()

    entry_insert = "INSERT INTO entries (ent_seq, priority, is_common) VALUES (?, ?, ?)"
    kanji_insert = "INSERT INTO kanji (text, entry_id, priority) VALUES (?, ?, ?)"
    kana_insert  = "INSERT INTO kana_forms (text, entry_id, priority) VALUES (?, ?, ?)"
    sense_insert = "INSERT INTO senses (entry_id, order_index, pos, misc, field, dialect) VALUES (?, ?, ?, ?, ?, ?)"
    gloss_insert = "INSERT INTO glosses (sense_id, order_index, gloss) VALUES (?, ?, ?)"
    used_ent_seqs = set()

    for entry in entries:
        ent_seq = int(entry.get("id"))
        insert_entry(
            conn,
            entry_insert,
            kanji_insert,
            kana_insert,
            sense_insert,
            gloss_insert,
            entry,
            ent_seq
        )
        used_ent_seqs.add(ent_seq)

    next_custom_ent_seq = -1
    for entry_index, entry in enumerate(extra_entries):
        ent_seq, next_custom_ent_seq = resolve_extra_ent_seq(
            entry,
            entry_index,
            used_ent_seqs,
            next_custom_ent_seq
        )

        insert_entry(
            conn,
            entry_insert,
            kanji_insert,
            kana_insert,
            sense_insert,
            gloss_insert,
            entry,
            ent_seq
        )
        used_ent_seqs.add(ent_seq)

    conn.commit()
    conn.execute("PRAGMA optimize")
    conn.close()


def main():
    start = time.time()
    ensure_input_exists()

    print("Building dictionary.sqlite...")
    print(f"JMdict SHA256: {sha256_of_file(JMDICT_PATH)}")
    if EXTRAS_PATH.exists():
        print(f"Extras SHA256: {sha256_of_file(EXTRAS_PATH)}")
    else:
        print("Extras SHA256: (missing; no supplemental entries loaded)")

    build_database()

    print(f"Done in {time.time() - start:.2f}s")
    print(f"Output: {OUTPUT_DB}")


if __name__ == "__main__":
    main()