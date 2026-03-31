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
KANJIDIC2_PATH = RESOURCES_DIR / "kanjidic2-all.json"
PITCH_ACCENT_PATH = RESOURCES_DIR / "pitch-accent.tsv"
SENTENCE_PAIRS_PATH = RESOURCES_DIR / "sentence-pairs.tsv"
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
            -- ke_pri priority tags only (ichi1, news1, spec1, gai1, nf01–nf48), comma-joined.
            priority TEXT,
            -- ke_inf information tags only (ateji, io, iK, oK, rK, sK), comma-joined.
            info TEXT,
            wordfreq_zipf REAL,
            FOREIGN KEY(entry_id) REFERENCES entries(id)
        );

        CREATE TABLE kana_forms (
            id INTEGER PRIMARY KEY,
            text TEXT NOT NULL,
            entry_id INTEGER NOT NULL,
            -- re_pri priority tags only (ichi1, news1, spec1, gai1, nf01–nf48), comma-joined.
            priority TEXT,
            -- re_inf information tags only (gikun, ik, ok, uK, sk), comma-joined.
            info TEXT,
            -- 1 when the re_nokanji flag is set (reading does not apply to any kanji form).
            re_nokanji INTEGER NOT NULL DEFAULT 0,
            wordfreq_zipf REAL,
            FOREIGN KEY(entry_id) REFERENCES entries(id)
        );

        CREATE TABLE kanji_kana_links (
            kanji_id INTEGER NOT NULL,
            kana_id INTEGER NOT NULL,
            jpdb_rank INTEGER,
            -- on/kun classification for this (kanji surface, kana reading) pair.
            -- 'on' | 'kun' | 'mixed' | 'unknown'. Populated after KANJIDIC2 import.
            reading_type TEXT,
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

        -- Sense-level application restrictions (stagk / stagr).
        -- type: 'stagk' restricts to a specific kanji form; 'stagr' restricts to a specific kana form.
        CREATE TABLE sense_restrictions (
            id INTEGER PRIMARY KEY,
            sense_id INTEGER NOT NULL,
            type TEXT NOT NULL CHECK(type IN ('stagk', 'stagr')),
            value TEXT NOT NULL,
            FOREIGN KEY(sense_id) REFERENCES senses(id)
        );

        -- Sense-level cross-references and antonyms (xref / ant).
        -- target may be a bare word, "word・reading", or "word・reading・senseNum".
        CREATE TABLE sense_references (
            id INTEGER PRIMARY KEY,
            sense_id INTEGER NOT NULL,
            type TEXT NOT NULL CHECK(type IN ('xref', 'ant')),
            target TEXT NOT NULL,
            FOREIGN KEY(sense_id) REFERENCES senses(id)
        );

        -- Loanword source information (lsource element).
        -- ls_wasei: 1 when wasei-eigo (Japanese-coined pseudo-loanword).
        -- ls_type: 'full' when entire word derives from source; 'part' for partial borrowings.
        CREATE TABLE lsource (
            id INTEGER PRIMARY KEY,
            sense_id INTEGER NOT NULL,
            lang TEXT NOT NULL,
            ls_wasei INTEGER NOT NULL DEFAULT 0,
            ls_type TEXT NOT NULL DEFAULT 'part',
            content TEXT,
            FOREIGN KEY(sense_id) REFERENCES senses(id)
        );

        CREATE INDEX idx_kanji_text ON kanji(text);
        CREATE INDEX idx_kana_text ON kana_forms(text);
        CREATE INDEX idx_entries_ent_seq ON entries(ent_seq);
        CREATE INDEX idx_kanji_entry_id ON kanji(entry_id);
        CREATE INDEX idx_kana_entry_id ON kana_forms(entry_id);
        CREATE INDEX idx_senses_entry_id ON senses(entry_id);
        CREATE INDEX idx_glosses_sense_id ON glosses(sense_id);
        CREATE INDEX idx_kkl_kana ON kanji_kana_links(kana_id);
        CREATE INDEX idx_sense_restrictions_sense_id ON sense_restrictions(sense_id);
        CREATE INDEX idx_sense_references_sense_id ON sense_references(sense_id);
        CREATE INDEX idx_lsource_sense_id ON lsource(sense_id);

        -- Per-character kanji data from KANJIDIC2.
        -- grade: 1–6 = kyōiku (elementary), 8 = jōyō (secondary), 9–10 = jinmeiyō.
        -- freq_mainichi: newspaper frequency rank (1–2501, lower = more common).
        -- radical: Kangxi radical number (1–214).
        -- jlpt_level: old 4-level JLPT (1 = most advanced, 4 = most elementary); many nulls.
        CREATE TABLE kanji_characters (
            id INTEGER PRIMARY KEY,
            literal TEXT NOT NULL UNIQUE,
            grade INTEGER,
            stroke_count INTEGER,
            freq_mainichi INTEGER,
            radical INTEGER,
            jlpt_level INTEGER
        );

        -- On'yomi, kun'yomi, and nanori readings for each kanji character.
        -- type: 'on' | 'kun' | 'nanori'
        -- on_type: sub-classification of onyomi origin: 'kan' | 'go' | 'tou' | 'kan'you'; null for non-on readings.
        -- Kun'yomi readings use a dot to separate the okurigana stem, e.g. 'た.べる'.
        CREATE TABLE kanji_readings (
            id INTEGER PRIMARY KEY,
            kanji_id INTEGER NOT NULL,
            reading TEXT NOT NULL,
            type TEXT NOT NULL CHECK(type IN ('on', 'kun', 'nanori')),
            on_type TEXT,
            FOREIGN KEY(kanji_id) REFERENCES kanji_characters(id)
        );

        -- Character-level meanings from KANJIDIC2 (distinct from word glosses in JMdict).
        -- Multiple languages available: 'en', 'fr', 'es', 'pt'.
        CREATE TABLE kanji_meanings (
            id INTEGER PRIMARY KEY,
            kanji_id INTEGER NOT NULL,
            lang TEXT NOT NULL,
            meaning TEXT NOT NULL,
            FOREIGN KEY(kanji_id) REFERENCES kanji_characters(id)
        );

        -- Alternate forms of the same character (異体字, 旧字体, etc.) from KANJIDIC2.
        -- type: encoding scheme of the value, e.g. 'jis208', 'ucs' (hex codepoint), 'nelson_c'.
        CREATE TABLE kanji_variants (
            id INTEGER PRIMARY KEY,
            kanji_id INTEGER NOT NULL,
            type TEXT NOT NULL,
            value TEXT NOT NULL,
            FOREIGN KEY(kanji_id) REFERENCES kanji_characters(id)
        );

        CREATE INDEX idx_kanji_char_literal ON kanji_characters(literal);
        CREATE INDEX idx_kanji_readings_kanji_id ON kanji_readings(kanji_id);
        CREATE INDEX idx_kanji_readings_reading ON kanji_readings(reading);
        CREATE INDEX idx_kanji_meanings_kanji_id ON kanji_meanings(kanji_id);
        CREATE INDEX idx_kanji_variants_kanji_id ON kanji_variants(kanji_id);

        -- Pitch accent entries from UniDic. word/kana may match multiple entries (different kinds).
        -- accent: downstep position (0 = flat/heiban). morae: mora count of the kana form.
        CREATE TABLE pitch_accent (
            id INTEGER PRIMARY KEY,
            word TEXT NOT NULL,
            kana TEXT NOT NULL,
            kind TEXT,
            accent INTEGER NOT NULL,
            morae INTEGER NOT NULL
        );

        CREATE INDEX idx_pitch_accent_word ON pitch_accent(word);
        CREATE INDEX idx_pitch_accent_kana ON pitch_accent(kana);

        -- Japanese-English sentence pairs from Tatoeba.
        -- ja_id/en_id are Tatoeba sentence IDs. One ja_id may map to multiple en_id translations.
        CREATE TABLE sentence_pairs (
            ja_id INTEGER NOT NULL,
            japanese TEXT NOT NULL,
            en_id INTEGER NOT NULL,
            english TEXT NOT NULL,
            PRIMARY KEY (ja_id, en_id)
        );

        CREATE INDEX idx_sentence_pairs_ja_id ON sentence_pairs(ja_id);

        -- FTS5 virtual table for fast substring search on Japanese sentence text.
        -- Enables efficient LIKE-equivalent queries without full table scans.
        CREATE VIRTUAL TABLE sentence_pairs_fts USING fts5(
            japanese,
            content=sentence_pairs,
            content_rowid=rowid,
            tokenize='unicode61'
        );
        """
    )


# ke_inf tags that carry orthographic information (distinct from ke_pri frequency/priority tags).
KE_INF_TAGS = {"ateji", "io", "iK", "oK", "rK", "sK"}

# re_inf tags that carry reading information (distinct from re_pri frequency/priority tags).
RE_INF_TAGS = {"gikun", "ik", "ok", "uK", "sk"}


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
                "INSERT INTO kanji (text, entry_id, priority, info) VALUES (?, ?, ?, ?)",
                (k, entry_id, None, None),
            )
            kanji_rows.append((cur.lastrowid, k))
        else:
            tags = k.get("tags") or []
            # Separate ke_pri frequency/priority tags from ke_inf orthographic-info tags.
            pri_tags = [t for t in tags if t not in KE_INF_TAGS]
            inf_tags = [t for t in tags if t in KE_INF_TAGS]
            priority_str = ",".join(sorted(set(pri_tags))) if pri_tags else None
            info_str = ",".join(sorted(set(inf_tags))) if inf_tags else None
            cur = conn.execute(
                "INSERT INTO kanji (text, entry_id, priority, info) VALUES (?, ?, ?, ?)",
                (k["text"], entry_id, priority_str, info_str),
            )
            kanji_rows.append((cur.lastrowid, k["text"]))

    kana_rows = []
    for r in entry.get("kana", []):
        if isinstance(r, str):
            cur = conn.execute(
                "INSERT INTO kana_forms (text, entry_id, priority, info, re_nokanji) VALUES (?, ?, ?, ?, ?)",
                (r, entry_id, None, None, 0),
            )
            kana_rows.append((cur.lastrowid, r, frozenset()))
        else:
            tags = r.get("tags") or []
            # Separate re_pri frequency/priority tags from re_inf reading-info tags.
            pri_tags = [t for t in tags if t not in RE_INF_TAGS]
            inf_tags = [t for t in tags if t in RE_INF_TAGS]
            priority_str = ",".join(sorted(set(pri_tags))) if pri_tags else None
            info_str = ",".join(sorted(set(inf_tags))) if inf_tags else None
            nokanji = 1 if r.get("nokanji") else 0
            cur = conn.execute(
                "INSERT INTO kana_forms (text, entry_id, priority, info, re_nokanji) VALUES (?, ?, ?, ?, ?)",
                (r["text"], entry_id, priority_str, info_str, nokanji),
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

        # stagk restrictions: sense applies only to specific kanji forms.
        for k_text in (sense.get("appliesToKanji") or []):
            if k_text != "*":
                conn.execute(
                    "INSERT INTO sense_restrictions (sense_id, type, value) VALUES (?, 'stagk', ?)",
                    (sense_id, k_text),
                )

        # stagr restrictions: sense applies only to specific kana forms.
        for k_text in (sense.get("appliesToKana") or []):
            if k_text != "*":
                conn.execute(
                    "INSERT INTO sense_restrictions (sense_id, type, value) VALUES (?, 'stagr', ?)",
                    (sense_id, k_text),
                )

        # xref cross-references to related entries.
        for xref in (sense.get("xref") or []):
            conn.execute(
                "INSERT INTO sense_references (sense_id, type, target) VALUES (?, 'xref', ?)",
                (sense_id, xref),
            )

        # ant antonyms.
        for ant in (sense.get("ant") or []):
            conn.execute(
                "INSERT INTO sense_references (sense_id, type, target) VALUES (?, 'ant', ?)",
                (sense_id, ant),
            )

        # lsource loanword origin records.
        for ls in (sense.get("languageSource") or []):
            lang = ls.get("lang") or ""
            wasei = 1 if ls.get("wasei") else 0
            ls_type = "full" if ls.get("full") else "part"
            content = ls.get("value")
            conn.execute(
                "INSERT INTO lsource (sense_id, lang, ls_wasei, ls_type, content) VALUES (?, ?, ?, ?, ?)",
                (sense_id, lang, wasei, ls_type, content),
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


def import_kanjidic2(conn):
    # Populates kanji_characters and kanji_readings from the scriptin/jmdict-simplified
    # kanjidic2-all JSON. Readings are nested under readingMeaning.groups[].readings[].
    # File must be downloaded separately; see data_manifest.json.
    if not KANJIDIC2_PATH.exists():
        print(f"  KANJIDIC2 file not found at {KANJIDIC2_PATH} — skipping")
        return

    print(f"  Importing KANJIDIC2 from {KANJIDIC2_PATH.name}...")

    with open(KANJIDIC2_PATH, "r", encoding="utf-8") as f:
        data = json.load(f)

    characters = data.get("characters", [])
    count = 0

    for char in characters:
        literal = char.get("literal")
        if not literal:
            continue

        misc = char.get("misc", {})
        grade = misc.get("grade")
        stroke_counts = misc.get("strokeCounts", [])
        stroke_count = stroke_counts[0] if stroke_counts else None
        freq_mainichi = misc.get("frequency")
        jlpt_level = misc.get("jlptLevel")

        # Kangxi radical: radicals is an array of {type, value} objects.
        radical = None
        for rad in char.get("radicals", []):
            if rad.get("type") == "classical":
                radical = rad.get("value")
                break

        cur = conn.execute(
            "INSERT INTO kanji_characters (literal, grade, stroke_count, freq_mainichi, radical, jlpt_level)"
            " VALUES (?, ?, ?, ?, ?, ?)",
            (literal, grade, stroke_count, freq_mainichi, radical, jlpt_level),
        )
        kanji_char_id = cur.lastrowid

        # Readings: ja_on and ja_kun are in readingMeaning.groups[].readings[].
        # Nanori are a separate flat array at readingMeaning.nanori[].
        reading_meaning = char.get("readingMeaning") or {}
        for group in reading_meaning.get("groups", []):
            for r in group.get("readings", []):
                r_type = r.get("type")
                value = r.get("value")
                if not value or r_type not in ("ja_on", "ja_kun"):
                    continue
                db_type = "on" if r_type == "ja_on" else "kun"
                on_type = r.get("onType") if r_type == "ja_on" else None
                conn.execute(
                    "INSERT INTO kanji_readings (kanji_id, reading, type, on_type) VALUES (?, ?, ?, ?)",
                    (kanji_char_id, value, db_type, on_type),
                )
            for m in group.get("meanings", []):
                lang = m.get("lang")
                meaning = m.get("value")
                if lang and meaning:
                    conn.execute(
                        "INSERT INTO kanji_meanings (kanji_id, lang, meaning) VALUES (?, ?, ?)",
                        (kanji_char_id, lang, meaning),
                    )

        for nanori in reading_meaning.get("nanori", []):
            if nanori:
                conn.execute(
                    "INSERT INTO kanji_readings (kanji_id, reading, type, on_type) VALUES (?, ?, 'nanori', NULL)",
                    (kanji_char_id, nanori),
                )

        for variant in misc.get("variants", []):
            v_type = variant.get("type")
            v_value = variant.get("value")
            if v_type and v_value:
                conn.execute(
                    "INSERT INTO kanji_variants (kanji_id, type, value) VALUES (?, ?, ?)",
                    (kanji_char_id, v_type, v_value),
                )

        count += 1

    print(f"  Done: {count} kanji characters imported")


def import_pitch_accent(conn):
    # Populates pitch_accent from pitch-accent.tsv (UniDic-derived).
    # Columns: id, word, kana, kind, accent, morae.
    if not PITCH_ACCENT_PATH.exists():
        print(f"  Pitch accent file not found at {PITCH_ACCENT_PATH} — skipping")
        return

    print(f"  Importing pitch accent from {PITCH_ACCENT_PATH.name}...")

    import csv
    count = 0
    with open(PITCH_ACCENT_PATH, encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f, delimiter="\t")
        for row in reader:
            conn.execute(
                "INSERT INTO pitch_accent (id, word, kana, kind, accent, morae) VALUES (?, ?, ?, ?, ?, ?)",
                (int(row["id"]), row["word"], row["kana"], row["kind"] or None,
                 int(row["accent"]), int(row["morae"])),
            )
            count += 1

    print(f"  Done: {count} pitch accent entries imported")


def import_sentence_pairs(conn):
    # Populates sentence_pairs from sentence-pairs.tsv (Tatoeba-derived).
    # Columns (no header): ja_id, japanese, en_id, english.
    if not SENTENCE_PAIRS_PATH.exists():
        print(f"  Sentence pairs file not found at {SENTENCE_PAIRS_PATH} — skipping")
        return

    print(f"  Importing sentence pairs from {SENTENCE_PAIRS_PATH.name}...")

    import csv
    count = 0
    with open(SENTENCE_PAIRS_PATH, encoding="utf-8-sig", newline="") as f:
        reader = csv.reader(f, delimiter="\t")
        for row in reader:
            if len(row) != 4:
                continue
            ja_id, japanese, en_id, english = row
            conn.execute(
                "INSERT OR IGNORE INTO sentence_pairs (ja_id, japanese, en_id, english) VALUES (?, ?, ?, ?)",
                (int(ja_id), japanese, int(en_id), english),
            )
            count += 1

    print(f"  Done: {count} sentence pairs imported")


def katakana_to_hiragana(text):
    # Converts full-width katakana to hiragana (subtract 96 from each katakana codepoint).
    return "".join(chr(ord(ch) - 96) if 0x30A1 <= ord(ch) <= 0x30F6 else ch for ch in text)


def is_kanji(ch):
    # Returns True for CJK Unified Ideographs (main block + extension A).
    cp = ord(ch)
    return (0x4E00 <= cp <= 0x9FFF) or (0x3400 <= cp <= 0x4DBF)


def classify_reading_type(kanji_surface, kana_reading, readings_map):
    # Classifies a (kanji surface, kana reading) pair as 'on', 'kun', 'mixed', or 'unknown'.
    # Greedy left-to-right: for each kanji in the surface, match the longest on or kun
    # prefix in the remaining kana. On-readings are stored as hiragana; kun stems are before '.'.
    kanji_chars = [c for c in kanji_surface if is_kanji(c)]
    if not kanji_chars:
        return "kun"

    remaining = katakana_to_hiragana(kana_reading)
    types = []

    for char in kanji_chars:
        char_data = readings_map.get(char)
        if not char_data:
            types.append("unknown")
            continue

        best_type = None
        best_len = 0

        for r in char_data.get("on", []):
            if remaining.startswith(r) and len(r) > best_len:
                best_type = "on"
                best_len = len(r)

        for r in char_data.get("kun", []):
            if remaining.startswith(r) and len(r) > best_len:
                best_type = "kun"
                best_len = len(r)

        types.append(best_type or "unknown")
        if best_len > 0:
            remaining = remaining[best_len:]

    known = [t for t in types if t != "unknown"]
    if not known:
        return "unknown"
    unique = set(known)
    return unique.pop() if len(unique) == 1 else "mixed"


def classify_reading_types(conn):
    # Populates reading_type on kanji_kana_links by decomposing each kana reading
    # against per-character on/kun readings from KANJIDIC2.
    # Must run after import_kanjidic2. Skips gracefully if kanji_characters is empty.
    cur = conn.execute("SELECT COUNT(*) FROM kanji_characters")
    if cur.fetchone()[0] == 0:
        print("  KANJIDIC2 data absent — skipping reading type classification")
        return

    print("  Classifying reading types (on/kun)...")

    # Build lookup: literal -> {on: [hiragana_readings], kun: [hiragana_stems]}
    cur = conn.execute(
        "SELECT kc.literal, kr.type, kr.reading"
        " FROM kanji_characters kc JOIN kanji_readings kr ON kr.kanji_id = kc.id"
        " WHERE kr.type IN ('on', 'kun')"
    )
    readings_map = {}
    for literal, r_type, reading in cur.fetchall():
        if literal not in readings_map:
            readings_map[literal] = {"on": [], "kun": []}
        if r_type == "on":
            readings_map[literal]["on"].append(katakana_to_hiragana(reading))
        else:
            stem = reading.split(".")[0]
            if stem:
                readings_map[literal]["kun"].append(stem)

    cur = conn.execute(
        "SELECT kkl.kanji_id, kkl.kana_id, k.text, kf.text"
        " FROM kanji_kana_links kkl"
        " JOIN kanji k ON k.id = kkl.kanji_id"
        " JOIN kana_forms kf ON kf.id = kkl.kana_id"
    )
    links = cur.fetchall()

    for kanji_id, kana_id, kanji_text, kana_text in links:
        r_type = classify_reading_type(kanji_text, kana_text, readings_map)
        conn.execute(
            "UPDATE kanji_kana_links SET reading_type = ? WHERE kanji_id = ? AND kana_id = ?",
            (r_type, kanji_id, kana_id),
        )

    print(f"  Done: {len(links)} links classified")


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

    print("Importing KANJIDIC2 data...")
    import_kanjidic2(conn)
    classify_reading_types(conn)

    print("Importing pitch accent data...")
    import_pitch_accent(conn)

    print("Importing sentence pairs...")
    import_sentence_pairs(conn)

    print("Building sentence FTS index...")
    conn.execute("INSERT INTO sentence_pairs_fts(sentence_pairs_fts) VALUES('rebuild')")

    print("Materializing surface_readings lookup table...")
    conn.executescript(
        """
        CREATE TABLE surface_readings (
            surface TEXT NOT NULL,
            reading TEXT NOT NULL,
            best_rank INTEGER NOT NULL,
            jpdb_rank INTEGER,
            wordfreq_zipf REAL
        );

        INSERT INTO surface_readings (surface, reading, best_rank, jpdb_rank, wordfreq_zipf)
        SELECT surface, reading, best_rank, jpdb_rank, wordfreq_zipf FROM (
            SELECT kj.text AS surface, kf.text AS reading,
                   MIN(COALESCE(kkl.jpdb_rank, 9999999)) AS best_rank,
                   MIN(kkl.jpdb_rank) AS jpdb_rank,
                   MAX(kj.wordfreq_zipf) AS wordfreq_zipf
            FROM kanji kj
            JOIN kana_forms kf ON kf.entry_id = kj.entry_id
            LEFT JOIN kanji_kana_links kkl ON kkl.kanji_id = kj.id AND kkl.kana_id = kf.id
            GROUP BY kj.text, kf.text
            UNION ALL
            SELECT kf.text, kf.text, 9999999, NULL, kf.wordfreq_zipf
            FROM kana_forms kf
            WHERE kf.entry_id NOT IN (SELECT entry_id FROM kanji)
        )
        ORDER BY surface ASC, best_rank ASC, reading ASC;

        CREATE INDEX idx_surface_readings_surface ON surface_readings(surface);
        """
    )
    surface_count = conn.execute("SELECT COUNT(*) FROM surface_readings").fetchone()[0]
    print(f"  Done: {surface_count} surface_readings rows materialized")

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
