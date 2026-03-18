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
JPDB_PATH = RESOURCES_DIR / "JPDB_v2.2_Frequency_Kana.json"
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
            ent_seq INTEGER UNIQUE
        );

        CREATE TABLE kanji (
            id INTEGER PRIMARY KEY,
            text TEXT NOT NULL,
            entry_id INTEGER NOT NULL,
            priority TEXT,
            wordfreq_zipf REAL,
            FOREIGN KEY(entry_id) REFERENCES entries(id)
        );

        CREATE TABLE kana_forms (
            id INTEGER PRIMARY KEY,
            text TEXT NOT NULL,
            entry_id INTEGER NOT NULL,
            priority TEXT,
            wordfreq_zipf REAL,
            FOREIGN KEY(entry_id) REFERENCES entries(id)
        );

        CREATE TABLE kanji_kana_links (
            kanji_id INTEGER NOT NULL,
            kana_id INTEGER NOT NULL,
            jpdb_rank INTEGER,
            PRIMARY KEY (kanji_id, kana_id),
            FOREIGN KEY(kanji_id) REFERENCES kanji(id),
            FOREIGN KEY(kana_id) REFERENCES kana_forms(id)
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

        CREATE VIEW word_frequency AS
            SELECT k.entry_id, k.id AS kanji_id, kf.id AS kana_id,
                   kkl.jpdb_rank, k.wordfreq_zipf
            FROM kanji_kana_links kkl
            JOIN kanji k ON k.id = kkl.kanji_id
            JOIN kana_forms kf ON kf.id = kkl.kana_id
            UNION ALL
            SELECT kf.entry_id, NULL AS kanji_id, kf.id AS kana_id,
                   NULL AS jpdb_rank, kf.wordfreq_zipf
            FROM kana_forms kf
            WHERE kf.entry_id NOT IN (SELECT entry_id FROM kanji);

        CREATE INDEX idx_kanji_text ON kanji(text);
        CREATE INDEX idx_kana_text ON kana_forms(text);
        CREATE INDEX idx_entries_ent_seq ON entries(ent_seq);
        CREATE INDEX idx_kanji_entry_id ON kanji(entry_id);
        CREATE INDEX idx_kana_entry_id ON kana_forms(entry_id);
        CREATE INDEX idx_senses_entry_id ON senses(entry_id);
        CREATE INDEX idx_glosses_sense_id ON glosses(sense_id);
        CREATE INDEX idx_kkl_kana ON kanji_kana_links(kana_id);
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
    #     kanji?: [ string | { text: string, tags?: [string] } ],
    #     kana?: [ string | { text: string, tags?: [string], appliesToKanji?: [string] } ],
    #     sense?: [
    #       {
    #         partOfSpeech?: [string],
    #         misc?: [string],
    #         field?: [string],
    #         dialect?: [string],
    #         gloss?: [ string | { text: string } ]
    #       }
    #     ],
    #     gloss?: string | { text: string } | [ string | { text: string } ]
    #       # shorthand allowed only when sense is omitted;
    #       # normalizes to sense: [{ gloss: [...] }]
    #   }
    # ]
    if not EXTRAS_PATH.exists():
        return []

    with open(EXTRAS_PATH, "r", encoding="utf-8") as f:
        data = json.load(f)

    if isinstance(data, list):
        return [normalize_extra_entry(entry, i) for i, entry in enumerate(data)]

    raise ValueError("Unexpected extras JSON structure")


def normalize_extra_entry(entry, entry_index):
    if not isinstance(entry, dict):
        raise ValueError(f"extras.json entry {entry_index} must be an object")

    normalized = dict(entry)

    for form_key in ("kanji", "kana"):
        val = normalized.get(form_key)
        if isinstance(val, str):
            normalized[form_key] = [val]
        elif val is not None and not isinstance(val, list):
            raise ValueError(
                f"extras.json entry {entry_index} field '{form_key}' must be a string or array"
            )

    shorthand_gloss = normalized.pop("gloss", None)
    existing_sense = normalized.get("sense")

    if shorthand_gloss is not None and existing_sense is not None:
        raise ValueError(
            f"extras.json entry {entry_index} cannot specify both 'gloss' shorthand and 'sense'"
        )

    if isinstance(existing_sense, str):
        normalized["sense"] = [{"gloss": [existing_sense]}]
    elif isinstance(existing_sense, dict):
        normalized["sense"] = [existing_sense]
    elif existing_sense is not None and not isinstance(existing_sense, list):
        raise ValueError(
            f"extras.json entry {entry_index} field 'sense' must be a string, object, or array"
        )

    if shorthand_gloss is not None:
        gloss_list = shorthand_gloss if isinstance(shorthand_gloss, list) else [shorthand_gloss]
        normalized["sense"] = [{"gloss": gloss_list}]

    return normalized


def insert_entry(conn, entry, ent_seq):
    # Inserts one entry and its forms/senses. Returns (entry_id, kanji_rows, kana_rows)
    # where kanji_rows = [(kanji_id, text)] and kana_rows = [(kana_id, text, applies_to_kanji_set)].
    cur = conn.execute("INSERT INTO entries (ent_seq) VALUES (?)", (ent_seq,))
    entry_id = cur.lastrowid

    kanji_rows = []
    for k in entry.get("kanji", []):
        if isinstance(k, str):
            cur = conn.execute(
                "INSERT INTO kanji (text, entry_id, priority) VALUES (?, ?, ?)",
                (k, entry_id, None),
            )
            kanji_rows.append((cur.lastrowid, k))
        else:
            tags = k.get("tags") or []
            priority_str = ",".join(sorted(set(tags))) if tags else None
            cur = conn.execute(
                "INSERT INTO kanji (text, entry_id, priority) VALUES (?, ?, ?)",
                (k["text"], entry_id, priority_str),
            )
            kanji_rows.append((cur.lastrowid, k["text"]))

    kana_rows = []
    for r in entry.get("kana", []):
        if isinstance(r, str):
            cur = conn.execute(
                "INSERT INTO kana_forms (text, entry_id, priority) VALUES (?, ?, ?)",
                (r, entry_id, None),
            )
            kana_rows.append((cur.lastrowid, r, frozenset()))
        else:
            tags = r.get("tags") or []
            priority_str = ",".join(sorted(set(tags))) if tags else None
            cur = conn.execute(
                "INSERT INTO kana_forms (text, entry_id, priority) VALUES (?, ?, ?)",
                (r["text"], entry_id, priority_str),
            )
            applies = r.get("appliesToKanji") or ["*"]
            re_restr = frozenset() if applies == ["*"] else frozenset(applies)
            kana_rows.append((cur.lastrowid, r["text"], re_restr))

    # Build kanji_kana_links from re_restr data.
    # A kana with no restriction (empty frozenset) links to every kanji form.
    if kanji_rows:
        kanji_text_to_id = {text: kid for kid, text in kanji_rows}
        for kana_id, _kana_text, re_restr in kana_rows:
            if not re_restr:
                for kanji_id, _ in kanji_rows:
                    conn.execute(
                        "INSERT INTO kanji_kana_links (kanji_id, kana_id) VALUES (?, ?)",
                        (kanji_id, kana_id),
                    )
            else:
                for kanji_text in re_restr:
                    kanji_id = kanji_text_to_id.get(kanji_text)
                    if kanji_id is not None:
                        conn.execute(
                            "INSERT INTO kanji_kana_links (kanji_id, kana_id) VALUES (?, ?)",
                            (kanji_id, kana_id),
                        )

    senses = entry.get("sense") or []
    for s_idx, sense in enumerate(senses):
        pos = ",".join(sense.get("partOfSpeech", []) or []) or None
        misc = ",".join(sense.get("misc", []) or []) or None
        field = ",".join(sense.get("field", []) or []) or None
        dialect = ",".join(sense.get("dialect", []) or []) or None

        cur = conn.execute(
            "INSERT INTO senses (entry_id, order_index, pos, misc, field, dialect) VALUES (?, ?, ?, ?, ?, ?)",
            (entry_id, s_idx, pos, misc, field, dialect),
        )
        sense_id = cur.lastrowid

        for g_idx, gloss in enumerate(sense.get("gloss", [])):
            text = gloss.get("text", "") if isinstance(gloss, dict) else gloss
            conn.execute(
                "INSERT INTO glosses (sense_id, order_index, gloss) VALUES (?, ?, ?)",
                (sense_id, g_idx, text),
            )


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


def import_wordfreq(conn):
    # Populates wordfreq_zipf on kanji and kana_forms rows using the wordfreq Python package.
    # Requires: pip install wordfreq mecab-python3 ipadic
    try:
        from wordfreq import zipf_frequency
    except ImportError:
        print("  wordfreq not installed — skipping wordfreq import")
        return

    print("  Importing wordfreq Zipf scores...")

    cur = conn.execute("SELECT id, text FROM kanji")
    kanji_rows = cur.fetchall()
    for kanji_id, text in kanji_rows:
        score = zipf_frequency(text, "ja")
        conn.execute("UPDATE kanji SET wordfreq_zipf = ? WHERE id = ?", (score if score > 0 else None, kanji_id))

    cur = conn.execute("SELECT id, text FROM kana_forms")
    kana_rows = cur.fetchall()
    for kana_id, text in kana_rows:
        score = zipf_frequency(text, "ja")
        conn.execute("UPDATE kana_forms SET wordfreq_zipf = ? WHERE id = ?", (score if score > 0 else None, kana_id))

    print(f"  Done: {len(kanji_rows)} kanji, {len(kana_rows)} kana forms scored")


def import_jpdb(conn):
    # Populates jpdb_rank on kanji_kana_links using the JPDB v2.2 Frequency Kana dictionary.
    # File must be downloaded separately (not checked in); see data_manifest.json.
    # Only Shape B entries without the ㋕ marker are used (kanji expression + kana reading).
    if not JPDB_PATH.exists():
        print(f"  JPDB frequency file not found at {JPDB_PATH} — skipping")
        return

    print(f"  Importing JPDB frequency ranks from {JPDB_PATH.name}...")

    # Build lookup: (kanji_text, kana_text) → (kanji_id, kana_id)
    cur = conn.execute(
        """
        SELECT k.text, kf.text, kkl.kanji_id, kkl.kana_id
        FROM kanji_kana_links kkl
        JOIN kanji k ON k.id = kkl.kanji_id
        JOIN kana_forms kf ON kf.id = kkl.kana_id
        """
    )
    link_map = {}
    for kanji_text, kana_text, kanji_id, kana_id in cur.fetchall():
        link_map[(kanji_text, kana_text)] = (kanji_id, kana_id)

    with open(JPDB_PATH, "r", encoding="utf-8") as f:
        rows = json.load(f)

    updated = 0
    for row in rows:
        if len(row) < 3 or row[1] != "freq":
            continue

        payload = row[2]

        # Shape A: kana-only entry — no "reading" key. Not imported into kanji_kana_links.
        if "reading" not in payload:
            continue

        # Shape B: kanji expression with kana reading.
        # Only import non-㋕ entries (the kanji-context rank).
        freq_info = payload.get("frequency", {})
        display = freq_info.get("displayValue", "")
        if display.endswith("㋕"):
            continue

        kanji_text = row[0]
        kana_text = payload.get("reading", "")
        rank = freq_info.get("value")

        if rank is None:
            continue

        key = (kanji_text, kana_text)
        if key in link_map:
            kanji_id, kana_id = link_map[key]
            conn.execute(
                "UPDATE kanji_kana_links SET jpdb_rank = ? WHERE kanji_id = ? AND kana_id = ?",
                (rank, kanji_id, kana_id),
            )
            updated += 1

    print(f"  Done: {updated} kanji_kana_links updated with JPDB rank")


def build_database():
    if OUTPUT_DB.exists():
        OUTPUT_DB.unlink()

    conn = sqlite3.connect(OUTPUT_DB)
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("BEGIN")
    create_schema(conn)

    entries = load_jmdict_entries()
    extra_entries = load_extra_entries()

    used_ent_seqs = set()

    for entry in entries:
        ent_seq = int(entry.get("id"))
        insert_entry(conn, entry, ent_seq)
        used_ent_seqs.add(ent_seq)

    next_custom_ent_seq = -1
    for entry_index, entry in enumerate(extra_entries):
        ent_seq, next_custom_ent_seq = resolve_extra_ent_seq(
            entry, entry_index, used_ent_seqs, next_custom_ent_seq
        )
        insert_entry(conn, entry, ent_seq)
        used_ent_seqs.add(ent_seq)

    print("Importing frequency data...")
    import_wordfreq(conn)
    import_jpdb(conn)

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
