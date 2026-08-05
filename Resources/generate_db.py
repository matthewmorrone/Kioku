import json
import sqlite3
import hashlib
import bisect
from contextlib import contextmanager
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
JLPT_VOCAB_PATH = RESOURCES_DIR / "jlpt-vocab.tsv"
RADKFILE_PATH = RESOURCES_DIR / "radkfile2.utf8"
KRADFILE_PATH = RESOURCES_DIR / "kradfile2.utf8"
KANJIVG_PATH = RESOURCES_DIR / "kanjivg.xml"
OUTPUT_DB = RESOURCES_DIR / "dictionary.sqlite"

# Sort key written for surfaces with no frequency signal, so unranked rows sort last.
# MUST match the app's DictionaryStore.FrequencySQL.unrankedSort — the two encode the
# same "no rank" sentinel and ranking disagrees if they drift apart.
UNRANKED_RANK_SENTINEL = 9999999


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
            -- IPADic context IDs for this surface, harvested at build time via the mecab CLI.
            -- Used by the trie segmenter's Viterbi path to look up bigram costs directly in
            -- matrix.bin instead of averaging into POS-class buckets. left_id is consulted
            -- when this edge appears on the RIGHT side of a transition (i.e., something
            -- precedes it); right_id when on the LEFT (something follows). Null when the
            -- surface failed to tokenize cleanly through mecab.
            ipadic_left_id INTEGER,
            ipadic_right_id INTEGER,
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
            -- See ipadic_left_id / ipadic_right_id comment on kanji above.
            ipadic_left_id INTEGER,
            ipadic_right_id INTEGER,
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
            -- s_inf sense-level usage notes (e.g. "after the -te form of a verb",
            -- "esp. as 持ってる"), newline-joined when a sense carries several.
            info TEXT,
            FOREIGN KEY(entry_id) REFERENCES entries(id)
        );

        CREATE TABLE glosses (
            id INTEGER PRIMARY KEY,
            sense_id INTEGER NOT NULL,
            order_index INTEGER NOT NULL,
            gloss TEXT NOT NULL,
            FOREIGN KEY(sense_id) REFERENCES senses(id)
        );

        -- Always emit kana-form rows (alongside any kanji+kana rows). The earlier
        -- "WHERE entry_id NOT IN kanji" filter dropped the kana zipf for any entry that
        -- happened to have a kanji form, even when the kanji form is rare or never used —
        -- so kana-dominant words like ここ inherited only their rare-kanji zipf and
        -- mislabelled as Rare downstream.
        -- word_frequency is materialized as an INDEXED TABLE at the end of the build (see
        -- materialize_word_frequency below), NOT a view. As a view it was re-evaluated (a full
        -- UNION over kanji_kana_links + kana_forms, ~514k rows) on every dictionary lookup that
        -- LEFT JOINs it, and since it has no indexable entry_id, SQLite built an AUTOMATIC
        -- COVERING INDEX per query — a flat ~310ms tax on every lookup. A real table with an
        -- entry_id index turns that into an index seek. It can't be created here because the
        -- source tables (kanji.wordfreq_zipf, kanji_kana_links.jpdb_rank) aren't populated yet.

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

        -- FTS5 trigram tables backing Words-tab substring search. Trigram tokenizer
        -- indexes every 3-character substring of the source column, so MATCH 'hello'
        -- (5 chars) finds 'shellos', 'othello', 'helloween'... in O(log n) instead of
        -- the 432k/489k full-table scan that LIKE '%hello%' forces. Queries shorter
        -- than 3 chars must fall back to the indexed B-tree prefix path at query
        -- time — trigram can't represent 1- or 2-character lookups.
        CREATE VIRTUAL TABLE glosses_fts USING fts5(
            gloss,
            content=glosses,
            content_rowid=id,
            tokenize='trigram'
        );
        CREATE VIRTUAL TABLE kanji_fts USING fts5(
            text,
            content=kanji,
            content_rowid=id,
            tokenize='trigram'
        );
        CREATE VIRTUAL TABLE kana_forms_fts USING fts5(
            text,
            content=kana_forms,
            content_rowid=id,
            tokenize='trigram'
        );

        -- Multi-radical kanji decomposition data from EDRDG's RADKFILE/KRADFILE.
        -- `radicals` is the inventory of radical components (e.g. 木, 心, 亻) with their stroke
        -- counts. `kanji_radicals` is the many-to-many mapping populated from KRADFILE: one row
        -- per (kanji, radical) pair. The Kangxi `radical` column on `kanji_characters` is the
        -- character's INDEXING radical (one number 1–214); these tables capture all radical
        -- COMPONENTS that compose a character, which is what multi-radical lookup needs.
        CREATE TABLE radicals (
            radical TEXT PRIMARY KEY,
            stroke_count INTEGER NOT NULL
        );
        CREATE TABLE kanji_radicals (
            kanji TEXT NOT NULL,
            radical TEXT NOT NULL,
            PRIMARY KEY (kanji, radical),
            FOREIGN KEY (radical) REFERENCES radicals(radical)
        );
        CREATE INDEX idx_kanji_radicals_radical ON kanji_radicals(radical);
        CREATE INDEX idx_kanji_radicals_kanji ON kanji_radicals(kanji);

        -- KanjiVG stroke vector data. Each row is one stroke of one kanji, ordered by
        -- stroke_order so an animated rendering can draw strokes in the canonical sequence.
        -- path_d holds the SVG `d` attribute verbatim; the Swift layer parses it into CGPath.
        -- KanjiVG paths use a 109×109 canvas (with a small margin); the Swift view is
        -- responsible for normalizing to its render size.
        CREATE TABLE kanji_strokes (
            kanji TEXT NOT NULL,
            stroke_order INTEGER NOT NULL,
            path_d TEXT NOT NULL,
            PRIMARY KEY (kanji, stroke_order)
        );
        CREATE INDEX idx_kanji_strokes_kanji ON kanji_strokes(kanji);
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
        # s_inf notes may individually contain commas, so join with newline (never a comma)
        # and split on newline in Swift.
        info = "\n".join(sense.get("info", []) or []) or None

        cur = conn.execute(
            "INSERT INTO senses (entry_id, order_index, pos, misc, field, dialect, info) VALUES (?, ?, ?, ?, ?, ?, ?)",
            (entry_id, s_idx, pos, misc, field, dialect, info),
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


def resolve_extra_ent_seq(entry, entry_index, used_ent_seqs):
    # An extra entry's ent_seq is the STABLE key saved words anchor to, so it must not depend on
    # the entry's position in extras.json. Prefer an explicit ent_seq; otherwise derive one
    # deterministically from the entry's surface forms. The previous scheme assigned sequential
    # negatives by file order, so reordering or inserting an entry silently re-keyed every entry
    # after it.
    explicit_ent_seq = entry.get("ent_seq")
    if explicit_ent_seq is not None:
        ent_seq = int(explicit_ent_seq)
        if ent_seq in used_ent_seqs:
            raise ValueError(
                f"extras.json entry {entry_index} specifies ent_seq {ent_seq}, but that ent_seq is already in use"
            )
        return ent_seq

    # Content-derived negative ent_seq (JMdict sequences are positive), in a wide band to keep
    # collisions rare. Identity is the set of surface forms; on the rare collision, probe downward.
    kanji = entry.get("kanji") or []
    kana = entry.get("kana") or []
    key = "k:" + "|".join(kanji) + ";r:" + "|".join(kana)
    digest = hashlib.sha1(key.encode("utf-8")).hexdigest()
    ent_seq = -(int(digest[:12], 16) % 900_000_000) - 100_000_000
    while ent_seq in used_ent_seqs:
        ent_seq -= 1

    return ent_seq


def import_wordfreq(conn):
    # Populates wordfreq_zipf on kanji and kana_forms rows using the wordfreq Python package.
    #
    # This is a REQUIRED build phase, not an optional one. wordfreq is the ONLY frequency signal
    # for words usually written in kana (この, その, する, こと …): JPDB ranks only their rare kanji
    # spelling, never the everyday kana surface. A build without wordfreq silently produces an
    # all-NULL wordfreq_zipf column, which mislabels those extremely common words as "Rare" and
    # misorders their homographs — the exact bug this guard exists to prevent. So a missing package
    # is a hard error, never a silent skip. Install deps: pip install -r requirements.txt.
    try:
        from wordfreq import zipf_frequency
    except ImportError as exc:
        raise RuntimeError(
            "wordfreq is required to build dictionary.sqlite but is not installed. Install the "
            "build dependencies (ideally into ./.venv): pip install -r requirements.txt "
            "— or: pip install wordfreq mecab-python3 ipadic."
        ) from exc

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


def import_mecab_context_ids(conn):
    # Tags every kanji + kana surface with its IPADic (left_id, right_id) so the trie
    # segmenter's Viterbi path can look up real bigram costs in matrix.bin at runtime
    # instead of averaging the matrix into POS-class buckets (which loses the signal
    # that distinguishes good segmentations from bad ones).
    #
    # We invoke the homebrew mecab CLI in batch mode (stdin = one surface per line) and
    # parse its node-format output. For multi-token expansions (e.g. 勉強する → 勉強 + する),
    # we take the FIRST token's left_id (what precedes the entry connects to this side)
    # and the LAST token's right_id (what follows the entry sees this side). That keeps
    # the trie entry behaving correctly when surrounded by adjacent lattice edges.
    #
    # Requires `mecab` on PATH and `mecab-ipadic` installed (homebrew default location).
    import shutil
    import subprocess

    mecab_path = shutil.which("mecab")
    if mecab_path is None:
        print("  mecab CLI not on PATH — skipping IPADic context ID harvest")
        return

    print("  Harvesting IPADic context IDs via mecab CLI...")

    # Distinct surfaces across both tables; preserve insertion order so the streamed
    # output lines align with the input lines we sent on stdin.
    cur = conn.execute("SELECT DISTINCT text FROM kanji UNION SELECT DISTINCT text FROM kana_forms")
    surfaces = [row[0] for row in cur.fetchall() if row[0]]

    if not surfaces:
        print("  No surfaces to tag")
        return

    # Sentinel newlines/tabs in surfaces would desync the per-line input/output pairing.
    sanitized = [s.replace("\n", "").replace("\r", "").replace("\t", "") for s in surfaces]

    # %phl / %phr are mecab's "context id" format specifiers (left / right). EOS terminates
    # each input line's token list, so we can split mecab's output into per-surface groups.
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

    surface_to_ids = {}
    current_first = None
    current_last = None
    surface_index = 0

    for line in proc.stdout.splitlines():
        if line == "__EOS__":
            if surface_index < len(surfaces):
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

    # UPDATE in batches keyed by surface text. Both tables share the same text column.
    updated_kanji = 0
    updated_kana = 0
    for surface, ids in surface_to_ids.items():
        left_id, right_id = ids
        if left_id is None or right_id is None:
            continue
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

    print(f"  Tagged {updated_kanji} kanji rows + {updated_kana} kana rows with IPADic context IDs")

    # Strip symbol/EOS-class right IDs (≤4) from rows whose entry isn't an interjection.
    # MeCab returns one ID pair per surface, but JMdict can have multiple entries per surface;
    # the surface→IDs broadcast leaks interjection-class tags onto unrelated meanings (e.g.
    # entry 7's "のま" reading of 々 picks up right=2 which matrix.bin scores as cheap-to-glue,
    # letting のま beat の+またたく in Viterbi). Nulling these rows lets transitionCost fall
    # back to the POS-bucket scoring driven by the entry's actual JMdict POS bitfield.
    cleared_kana = conn.execute(
        """
        UPDATE kana_forms
           SET ipadic_left_id = NULL, ipadic_right_id = NULL
         WHERE ipadic_right_id IS NOT NULL
           AND ipadic_right_id <= 4
           AND NOT EXISTS (
               SELECT 1 FROM senses s
                WHERE s.entry_id = kana_forms.entry_id
                  AND s.pos LIKE '%int%'
           )
        """
    ).rowcount
    cleared_kanji = conn.execute(
        """
        UPDATE kanji
           SET ipadic_left_id = NULL, ipadic_right_id = NULL
         WHERE ipadic_right_id IS NOT NULL
           AND ipadic_right_id <= 4
           AND NOT EXISTS (
               SELECT 1 FROM senses s
                WHERE s.entry_id = kanji.entry_id
                  AND s.pos LIKE '%int%'
           )
        """
    ).rowcount
    print(f"  Cleared symbol-class IDs on {cleared_kana} kana + {cleared_kanji} kanji rows (POS mismatch)")


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


def import_jlpt_levels(conn):
    # Populates entry_jlpt_level from the Tanos-derived JLPT vocab list (Resources/jlpt-vocab.tsv,
    # columns: surface, reading, level — where level is the N-number, 5 = N5 easiest … 1 = N1 hardest).
    #
    # JLPT is a *vocabulary* list, so levels attach to JMdict ENTRIES, not kanji characters
    # (kanji_characters.jlpt_level is the separate, old 4-level per-character scale). Source rows are
    # matched to entries by surface: kanji form first (preferring an entry whose kana reading also
    # matches the list's reading, to disambiguate homographs), then a kana-form fallback for
    # kana-only words. A surface shared by multiple entries (homographs) tags all of them — we can't
    # know the intended sense, and over-tagging is the safe direction for a study filter.
    #
    # Owns its table + index (like materialize_word_frequency owns word_frequency) so the full build
    # and the standalone migrate_add_jlpt_levels.py share one code path. Idempotent: re-running
    # rebuilds the table from scratch.
    #
    # Source data: Jonathan Waller's JLPT lists (https://www.tanos.co.uk/jlpt/), CC BY. These are
    # unofficial estimates — no official JLPT vocab lists exist post-2010.
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS entry_jlpt_level (
            entry_id INTEGER PRIMARY KEY,
            level INTEGER NOT NULL,
            is_estimated INTEGER NOT NULL DEFAULT 0,
            FOREIGN KEY(entry_id) REFERENCES entries(id)
        )
        """
    )
    conn.execute("CREATE INDEX IF NOT EXISTS idx_entry_jlpt_level ON entry_jlpt_level(level)")
    conn.execute("DELETE FROM entry_jlpt_level")

    if not JLPT_VOCAB_PATH.exists():
        print(f"  JLPT vocab file not found at {JLPT_VOCAB_PATH} — skipping")
        return

    print(f"  Importing JLPT levels from {JLPT_VOCAB_PATH.name}...")

    # Surface → entry ids, built once from the dictionary.
    kanji_map = {}
    for text, entry_id in conn.execute("SELECT text, entry_id FROM kanji"):
        kanji_map.setdefault(text, set()).add(entry_id)
    kana_map = {}
    entry_readings = {}
    for text, entry_id in conn.execute("SELECT text, entry_id FROM kana_forms"):
        kana_map.setdefault(text, set()).add(entry_id)
        entry_readings.setdefault(entry_id, set()).add(text)

    best = {}  # entry_id → easiest (highest N-number) level seen
    total_rows = 0
    matched_rows = 0
    with open(JLPT_VOCAB_PATH, encoding="utf-8") as f:
        next(f, None)  # header
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 3:
                continue
            surface, reading, level_s = parts[0].strip(), parts[1].strip(), parts[2].strip()
            if not surface or not level_s.isdigit():
                continue
            total_rows += 1
            level = int(level_s)

            ids = set()
            if surface in kanji_map:
                kanji_ids = kanji_map[surface]
                if reading:
                    reading_matched = {e for e in kanji_ids if reading in entry_readings.get(e, ())}
                    ids = reading_matched or set(kanji_ids)
                else:
                    ids = set(kanji_ids)
            elif surface in kana_map:
                ids = set(kana_map[surface])

            if not ids:
                continue
            matched_rows += 1
            for entry_id in ids:
                if entry_id not in best or level > best[entry_id]:
                    best[entry_id] = level

    conn.executemany(
        "INSERT OR REPLACE INTO entry_jlpt_level (entry_id, level) VALUES (?, ?)",
        list(best.items()),
    )
    print(
        f"  Done: {len(best)} entries tagged ({matched_rows}/{total_rows} source rows matched)"
    )


def estimate_jlpt_levels_from_frequency(conn):
    # Extends entry_jlpt_level with best-effort estimates for entries the Tanos list didn't cover,
    # via a k-nearest-neighbors vote over wordfreq_zipf trained on the entries Tanos DID label.
    # Must run after materialize_word_frequency (needs word_frequency populated) and after
    # import_jlpt_levels (needs the labeled training set).
    #
    # Quantile analysis of the labeled set showed frequency only weakly separates JLPT levels: N1
    # and N2 are statistically indistinguishable (medians 4.03 vs 3.96, IQRs almost fully
    # overlapping), and N3/N4/N5 overlap heavily too despite a real median gradient (4.56/4.67/
    # 4.88 — more common as the level gets easier, as expected). A plain nearest-mean classifier
    # would misclassify constantly around the N1/N2 boundary; k-NN at least reflects the true
    # local density at each frequency rather than collapsing every level to one number. These are
    # estimates, not verified labels — is_estimated=1 lets callers tell the difference.
    has_table = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='word_frequency'"
    ).fetchone()
    if not has_table:
        print("  word_frequency table missing — skipping frequency-based JLPT estimation")
        return

    entry_zipf = dict(conn.execute(
        "SELECT entry_id, MAX(wordfreq_zipf) FROM word_frequency "
        "WHERE wordfreq_zipf IS NOT NULL GROUP BY entry_id"
    ))

    labeled = conn.execute("SELECT entry_id, level FROM entry_jlpt_level").fetchall()
    labeled_ids = {entry_id for entry_id, _ in labeled}
    training = sorted(
        (
            (entry_zipf[entry_id], level)
            for entry_id, level in labeled
            if entry_id in entry_zipf
        ),
        key=lambda pair: pair[0],
    )
    if len(training) < 50:
        print("  Not enough labeled+frequency-scored entries to train a JLPT estimator — skipping")
        return
    training_zipf = [z for z, _ in training]

    # Raw neighbor-count voting is biased by training-set density, not true class likelihood: N1
    # has both the most labeled examples (3162) AND the widest frequency spread (it reaches deep
    # into the same low-frequency territory most of the ~190k uncovered dictionary occupies), so
    # N1 examples are locally present near almost any word's frequency and structurally dominate
    # a raw vote — a first attempt classified 86% of new entries as N1 for exactly this reason.
    # Weighting each neighbor's vote by 1/class_size approximates a proper posterior (P(level|zipf)
    # instead of raw local count) so a level's sheer training-set size stops mattering — only how
    # concentrated it is AT THIS zipf value relative to its own overall spread does.
    class_counts = {}
    for _, level in training:
        class_counts[level] = class_counts.get(level, 0) + 1

    k = 25

    # Finds the k training points nearest `zipf` by absolute distance (a simple two-pointer
    # expansion from the sorted-array insertion point — no need for a proper spatial index at
    # this scale), then returns the class-size-weighted majority vote among them.
    def estimate_level(zipf):
        insertion = bisect.bisect_left(training_zipf, zipf)
        lo, hi = insertion, insertion
        neighbors = []
        while len(neighbors) < k and (lo > 0 or hi < len(training)):
            left_dist = zipf - training_zipf[lo - 1] if lo > 0 else float("inf")
            right_dist = training_zipf[hi] - zipf if hi < len(training) else float("inf")
            if left_dist <= right_dist:
                lo -= 1
                neighbors.append(training[lo])
            else:
                neighbors.append(training[hi])
                hi += 1
        votes = {}
        for _, level in neighbors:
            votes[level] = votes.get(level, 0) + 1 / class_counts[level]
        return max(votes.items(), key=lambda kv: kv[1])[0]

    to_insert = [
        (entry_id, estimate_level(zipf))
        for entry_id, zipf in entry_zipf.items()
        if entry_id not in labeled_ids
    ]
    conn.executemany(
        "INSERT OR IGNORE INTO entry_jlpt_level (entry_id, level, is_estimated) VALUES (?, ?, 1)",
        to_insert,
    )
    print(f"  Done: {len(to_insert)} additional entries estimated via frequency k-NN (k={k})")


# Functional/deictic POS tags (particle, copula, auxiliary, pre-noun adjectival) — an entry
# with any sense tagged this way is what a bare-kana lookup almost always intends (は → topic
# particle, not 派 "faction"). Must match DictionaryStore.FrequencySQL.functionalPosMatch's
# tag set exactly — see that Swift file for why this needs to be one shared definition.
_FUNCTIONAL_POS_TAGS = {"prt", "cop", "aux", "adj-pn"}


def _is_functional_pos(pos_field):
    # pos is a comma-joined tag string (e.g. "prt,exp"); aux-* (aux-v, aux-adj, …) counts too.
    if not pos_field:
        return False
    tags = pos_field.split(",")
    return any(tag in _FUNCTIONAL_POS_TAGS or tag.startswith("aux-") for tag in tags)


# Hiragana (U+3040-U+309F) + katakana (U+30A0-U+30FF) blocks. Must match
# Kioku/Dictionary/ScriptClassifier.swift's isPureKana ranges exactly — this decides which
# fetchMatchedEntries mode (matchKana-only vs matchKanji-only) a surface is ranked under, so
# materialize_canonical_entry_ids has to gate its functional-POS tier on the identical test or
# the two implementations disagree on script-mixed rankings.
_KANA_RANGES = ((0x3040, 0x309F), (0x30A0, 0x30FF))


def _is_pure_kana(text):
    # Registered as a SQLite scalar function (IS_PURE_KANA) applied to surface, a NOT NULL TEXT
    # column, so SQLite itself never hands this a non-str/NULL value in practice — but a Python
    # UDF that raises on unexpected input aborts the whole materialize_canonical_entry_ids query
    # rather than just misclassifying one row, so guard defensively anyway.
    if not isinstance(text, str) or not text:
        return False
    return all(any(lo <= ord(ch) <= hi for lo, hi in _KANA_RANGES) for ch in text)


def populate_functional_pos(conn):
    # Precomputes DictionaryStore.FrequencySQL.functionalPosMatch's "does this entry have a
    # functional-POS sense" check into a plain indexed table instead of a correlated EXISTS +
    # LIKE '%,tag,%' subquery re-evaluated at every app startup. That subquery is fine for the
    # live interactive lookup (one entry checked at a time) but was the dominant cost — ~4s of
    # a ~7s cold start — when populateCanonicalEntryIDMap ran it across all ~450k dictionary
    # surfaces. A primary-key EXISTS lookup against this table replaces it at query time.
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS entry_functional_pos (
            entry_id INTEGER PRIMARY KEY,
            FOREIGN KEY(entry_id) REFERENCES entries(id)
        )
        """
    )
    conn.execute("DELETE FROM entry_functional_pos")

    matched_entry_ids = {
        entry_id
        for entry_id, pos in conn.execute("SELECT entry_id, pos FROM senses")
        if _is_functional_pos(pos)
    }

    conn.executemany(
        "INSERT INTO entry_functional_pos (entry_id) VALUES (?)",
        [(entry_id,) for entry_id in matched_entry_ids],
    )
    print(f"  Done: {len(matched_entry_ids)} entries tagged as functional/deictic POS")


def import_radicals(conn):
    # Populates `radicals` and `kanji_radicals` from RADKFILE2 + KRADFILE2 (EDRDG).
    # RADKFILE format: header lines start with '#' and are skipped. A '$' line introduces one
    # radical and looks like "$ <radical> <stroke_count> [unicode_hex]". Subsequent non-$/non-#
    # lines hold the kanji that contain that radical (space-separated). KRADFILE format: each
    # data line is "<kanji> : <radical1> <radical2> ...". We use RADKFILE for stroke counts and
    # KRADFILE for the kanji→radical edges (RADKFILE gives the same edges from the other direction
    # but KRADFILE's per-kanji rows are simpler to parse).
    if not RADKFILE_PATH.exists() and not KRADFILE_PATH.exists():
        print(f"  Radical files not found in {RESOURCES_DIR} — skipping multi-radical input")
        return

    radical_strokes = {}
    if RADKFILE_PATH.exists():
        print(f"  Parsing radicals from {RADKFILE_PATH.name}...")
        with open(RADKFILE_PATH, encoding="utf-8") as f:
            for raw in f:
                line = raw.rstrip("\n")
                if line.startswith("#") or not line.strip():
                    continue
                if line.startswith("$"):
                    # "$ <radical> <strokes> [...]"
                    parts = line.split()
                    if len(parts) >= 3:
                        radical = parts[1]
                        try:
                            strokes = int(parts[2])
                        except ValueError:
                            continue
                        radical_strokes[radical] = strokes
        print(f"  Done: {len(radical_strokes)} radicals indexed")
    else:
        print(f"  RADKFILE not found at {RADKFILE_PATH} — radicals table will be sparse")

    # Buffer the kanji→radical edges and insert them AFTER the radicals rows so the FK
    # (kanji_radicals.radical → radicals.radical) can resolve. SQLite enforces FKs per-statement
    # when PRAGMA foreign_keys = ON, so we cannot interleave the edge inserts with the parse.
    edge_rows = []
    if KRADFILE_PATH.exists():
        print(f"  Parsing kanji decompositions from {KRADFILE_PATH.name}...")
        with open(KRADFILE_PATH, encoding="utf-8") as f:
            for raw in f:
                line = raw.rstrip("\n")
                if line.startswith("#") or ":" not in line:
                    continue
                left, _, right = line.partition(":")
                kanji = left.strip()
                if not kanji:
                    continue
                for radical in right.split():
                    radical = radical.strip()
                    if not radical:
                        continue
                    # Backfill the stroke count if RADKFILE didn't ship a $-record for this radical.
                    if radical not in radical_strokes:
                        radical_strokes[radical] = 0
                    edge_rows.append((kanji, radical))
        print(f"  Done: {len(edge_rows)} kanji→radical edges parsed")
    else:
        print(f"  KRADFILE not found at {KRADFILE_PATH} — kanji_radicals table will be empty")

    for radical, strokes in radical_strokes.items():
        conn.execute(
            "INSERT OR REPLACE INTO radicals (radical, stroke_count) VALUES (?, ?)",
            (radical, strokes),
        )

    if edge_rows:
        conn.executemany(
            "INSERT OR IGNORE INTO kanji_radicals (kanji, radical) VALUES (?, ?)",
            edge_rows,
        )


def import_kanjivg(conn):
    # Parses the KanjiVG single-file XML and populates kanji_strokes with one row per stroke.
    # Each <kanji id="kvg:kanji_XXXXX"> in the XML wraps nested <g> groups; we don't care about
    # the grouping structure — we just want all <path> elements in document order, which gives
    # us the canonical stroke sequence (matches what KanjiVG's documentation describes).
    if not KANJIVG_PATH.exists():
        print(f"  KanjiVG file not found at {KANJIVG_PATH} — skipping stroke order data")
        return

    import xml.etree.ElementTree as ET

    print(f"  Parsing strokes from {KANJIVG_PATH.name}...")
    # KanjiVG uses the SVG namespace as default; we strip namespaces while parsing so .tag works
    # without the {namespace}Tag prefix everywhere.
    iterator = ET.iterparse(KANJIVG_PATH, events=("end",))
    kanji_count = 0
    stroke_count = 0
    for _event, elem in iterator:
        tag = elem.tag.split("}", 1)[-1]
        if tag != "kanji":
            continue
        # Element id looks like "kvg:kanji_06f22" → take the trailing hex and convert.
        elem_id = elem.get("id", "")
        if "_" not in elem_id:
            elem.clear()
            continue
        hex_part = elem_id.split("_", 1)[1]
        try:
            literal = chr(int(hex_part, 16))
        except ValueError:
            elem.clear()
            continue

        order = 0
        for path in elem.iter():
            inner_tag = path.tag.split("}", 1)[-1]
            if inner_tag != "path":
                continue
            d = path.get("d")
            if not d:
                continue
            order += 1
            conn.execute(
                "INSERT OR IGNORE INTO kanji_strokes (kanji, stroke_order, path_d) VALUES (?, ?, ?)",
                (literal, order, d),
            )
            stroke_count += 1

        if order > 0:
            kanji_count += 1

        # iterparse retains a reference to every parsed element by default — clearing keeps
        # memory bounded on the 14 MB XML file.
        elem.clear()

    print(f"  Done: {stroke_count} strokes across {kanji_count} kanji")


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


# (label, seconds) for every build phase, so a run self-reports where its time goes instead
# of relying on memory or stale comments. Populated by phase(); cleared at the start of each
# build_database() call so repeated in-process builds don't accumulate.
_PHASE_TIMINGS = []


# Time one build phase: print its label, run the wrapped body, then record and echo the elapsed
# seconds. Wrapping every phase in build_database() lets print_phase_summary() show a per-phase
# breakdown — the concrete measurement that settles how long a full rebuild actually takes.
@contextmanager
def phase(label):
    print(label)
    start = time.perf_counter()
    try:
        yield
    finally:
        elapsed = time.perf_counter() - start
        _PHASE_TIMINGS.append((label, elapsed))
        print(f"  → {elapsed:.2f}s")


# Print the recorded phases as a duration table sorted longest-first (with each phase's share of
# the total), so the slowest step is obvious at a glance. Called by main() after the build.
def print_phase_summary(total_elapsed):
    if not _PHASE_TIMINGS:
        return
    labels = [label.rstrip(". ") for label, _ in _PHASE_TIMINGS]
    label_width = max(len(label) for label in labels)
    print("\nBuild phase durations (longest first):")
    ordered = sorted(zip(labels, (t for _, t in _PHASE_TIMINGS)), key=lambda item: item[1], reverse=True)
    for label, elapsed in ordered:
        share = (elapsed / total_elapsed * 100) if total_elapsed else 0
        print(f"  {label.ljust(label_width)}  {elapsed:8.2f}s  {share:5.1f}%")
    print(f"  {'TOTAL'.ljust(label_width)}  {total_elapsed:8.2f}s")


def build_database():
    _PHASE_TIMINGS.clear()

    if OUTPUT_DB.exists():
        OUTPUT_DB.unlink()

    conn = sqlite3.connect(OUTPUT_DB)
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("BEGIN")

    with phase("Creating schema..."):
        create_schema(conn)

    with phase("Loading and inserting JMdict + extra entries..."):
        entries = load_jmdict_entries()
        extra_entries = load_extra_entries()

        used_ent_seqs = set()

        for entry in entries:
            ent_seq = int(entry.get("id"))
            insert_entry(conn, entry, ent_seq)
            used_ent_seqs.add(ent_seq)

        for entry_index, entry in enumerate(extra_entries):
            ent_seq = resolve_extra_ent_seq(entry, entry_index, used_ent_seqs)
            insert_entry(conn, entry, ent_seq)
            used_ent_seqs.add(ent_seq)

    with phase("Importing frequency data..."):
        import_wordfreq(conn)
        import_jpdb(conn)

    with phase("Tagging surfaces with IPADic context IDs..."):
        import_mecab_context_ids(conn)

    with phase("Importing KANJIDIC2 data..."):
        import_kanjidic2(conn)
        classify_reading_types(conn)

    with phase("Importing pitch accent data..."):
        import_pitch_accent(conn)

    with phase("Importing sentence pairs..."):
        import_sentence_pairs(conn)

    with phase("Importing JLPT vocabulary levels..."):
        import_jlpt_levels(conn)

    with phase("Precomputing functional/deictic POS entries..."):
        populate_functional_pos(conn)

    with phase("Building sentence FTS index..."):
        conn.execute("INSERT INTO sentence_pairs_fts(sentence_pairs_fts) VALUES('rebuild')")

    with phase("Building trigram FTS indexes for Words-tab substring search..."):
        # `rebuild` repopulates an external-content FTS5 table by scanning its content table —
        # cleaner than a manual INSERT...SELECT and tolerant of partial rebuilds.
        conn.execute("INSERT INTO glosses_fts(glosses_fts) VALUES('rebuild')")
        conn.execute("INSERT INTO kanji_fts(kanji_fts) VALUES('rebuild')")
        conn.execute("INSERT INTO kana_forms_fts(kana_forms_fts) VALUES('rebuild')")

    with phase("Importing radical decomposition data..."):
        import_radicals(conn)

    with phase("Importing KanjiVG stroke data..."):
        import_kanjivg(conn)

    with phase("Materializing frequency lookup tables..."):
        materialize_surface_readings(conn)
        materialize_word_frequency(conn)

    with phase("Estimating JLPT levels for unlabeled entries from frequency..."):
        estimate_jlpt_levels_from_frequency(conn)

    with phase("Materializing canonical entry id lookup table..."):
        materialize_canonical_entry_ids(conn)

    with phase("Finalizing (commit, ANALYZE, optimize)..."):
        conn.commit()
        conn.execute("ANALYZE")
        conn.execute("PRAGMA optimize")
        conn.close()


# The two materialization passes below are split into standalone functions so both the full
# build (main) and the frequency-only refresh (repopulate_frequency.py) drive them from one
# source of truth — re-running after import_wordfreq must rebuild these exactly the same way.
# DROP ... IF EXISTS makes them safe to re-run against an already-built database.
def materialize_surface_readings(conn):
    print("Materializing surface_readings lookup table...")
    conn.executescript(
        f"""
        DROP TABLE IF EXISTS surface_readings;

        CREATE TABLE surface_readings (
            surface TEXT NOT NULL,
            reading TEXT NOT NULL,
            best_rank INTEGER NOT NULL,
            jpdb_rank INTEGER,
            wordfreq_zipf REAL
        );

        WITH entry_rank AS (
            -- Per-entry best (lowest) jpdb rank, sourced from the kanji-kana links that carry it.
            -- JPDB ranks a single written form per entry (the kanji headword), so propagating that
            -- rank to every writing lets kana spellings (こと, する) and alternate writings inherit it
            -- instead of reading as rank-none. Mirrors fetchBestRankBySurface()/word_frequency so
            -- surface_readings agrees, surface-for-surface, with every other frequency consumer.
            SELECT k.entry_id AS entry_id, MIN(kkl.jpdb_rank) AS rank
            FROM kanji_kana_links kkl
            JOIN kanji k ON k.id = kkl.kanji_id
            WHERE kkl.jpdb_rank IS NOT NULL
            GROUP BY k.entry_id
        )
        INSERT INTO surface_readings (surface, reading, best_rank, jpdb_rank, wordfreq_zipf)
        SELECT surface, reading,
               MIN(best_rank) AS best_rank,
               MIN(jpdb_rank) AS jpdb_rank,
               MAX(wordfreq_zipf) AS wordfreq_zipf
        FROM (
            -- Kanji form as surface, kana form as reading. Prefers the exact (kanji,kana) pair rank,
            -- then falls back to the entry's best rank so the headword still sorts/scores when the
            -- specific pair is unranked. That fallback is deliberately entry-wide (same value for
            -- EVERY reading of a multi-reading entry, e.g. 二人's ににん and ふたり both inherit
            -- 474) — it exists so the surface still sorts/scores when NEITHER reading has its own
            -- pair-level rank, not to imply the readings are equally common. wordfreq_zipf is
            -- sourced per-READING (kf.wordfreq_zipf), not per-surface (kj.wordfreq_zipf) — this is
            -- the tiebreaker that actually distinguishes ににん (no real usage, NULL) from ふたり
            -- (real usage, ~4.27) when best_rank ties; see the ORDER BY below. Getting this from
            -- kj instead of kf was the root cause of 二人 defaulting to ににん and 一人 to
            -- いちにん — both readings shared one borrowed rank, so the tie broke alphabetically
            -- by reading (に before ふ, い before ひ) instead of by actual frequency.
            SELECT kj.text AS surface, kf.text AS reading,
                   COALESCE(kkl.jpdb_rank, er.rank, {UNRANKED_RANK_SENTINEL}) AS best_rank,
                   COALESCE(kkl.jpdb_rank, er.rank) AS jpdb_rank,
                   kf.wordfreq_zipf AS wordfreq_zipf
            FROM kanji kj
            JOIN kana_forms kf ON kf.entry_id = kj.entry_id
            LEFT JOIN kanji_kana_links kkl ON kkl.kanji_id = kj.id AND kkl.kana_id = kf.id
            LEFT JOIN entry_rank er ON er.entry_id = kj.entry_id
            UNION ALL
            -- Every kana form as its own surface. Without this branch the segmenter
            -- could only see kana surfaces for entries with NO kanji form at all, which
            -- silently excluded any word predominantly written in kana that also has
            -- a rare kanji form: このまま (この儘), ありがとう (有り難う), gikun like
            -- たゆたう (揺蕩う), and anything JMdict tags "usually written in kana alone."
            -- Hiragana-rendered text would then fall through to the unknown-token path,
            -- producing the kind of garbage segmentation 流されてたゆたうのこのまま showed.
            -- jpdb_rank/best_rank are INHERITED from the entry's headword rank (er.rank) — was NULL —
            -- so common kana spellings carry frequency instead of rendering "–" in the lookup/split
            -- editor; wordfreq_zipf is still carried from the kana form itself.
            SELECT kf.text AS surface, kf.text AS reading,
                   COALESCE(er.rank, {UNRANKED_RANK_SENTINEL}) AS best_rank,
                   er.rank AS jpdb_rank,
                   kf.wordfreq_zipf AS wordfreq_zipf
            FROM kana_forms kf
            LEFT JOIN entry_rank er ON er.entry_id = kf.entry_id
        )
        GROUP BY surface, reading
        -- wordfreq_zipf DESC breaks best_rank ties by actual per-reading usage before falling
        -- back to alphabetical — SQLite sorts NULL first in ASC / last in DESC, so a reading
        -- with no real frequency signal (e.g. ににん) correctly loses to one that has it (ふたり)
        -- instead of winning-by-coincidence on kana ordering. See the branch-1 comment above.
        ORDER BY surface ASC, MIN(best_rank) ASC, MAX(wordfreq_zipf) DESC, reading ASC;

        CREATE INDEX idx_surface_readings_surface ON surface_readings(surface);
        """
    )
    surface_count = conn.execute("SELECT COUNT(*) FROM surface_readings").fetchone()[0]
    print(f"  Done: {surface_count} surface_readings rows materialized")


def materialize_word_frequency(conn):
    # Materialize word_frequency as an indexed table now that wordfreq_zipf (on kanji/kana_forms)
    # and jpdb_rank (on kanji_kana_links) are fully populated. See the schema-phase note above for
    # why this is a table, not a view: the per-lookup LEFT JOIN was re-materializing the whole
    # view + building a throwaway index every call (~310ms). idx_wf_entry_id makes it an O(log n)
    # seek; kana_id/kanji_id indexes serve the reading-constrained frequency subqueries.
    print("Materializing word_frequency table...")
    conn.executescript(
        """
        DROP TABLE IF EXISTS word_frequency;

        CREATE TABLE word_frequency AS
            SELECT k.entry_id, k.id AS kanji_id, kf.id AS kana_id,
                   kkl.jpdb_rank, k.wordfreq_zipf
            FROM kanji_kana_links kkl
            JOIN kanji k ON k.id = kkl.kanji_id
            JOIN kana_forms kf ON kf.id = kkl.kana_id
            UNION ALL
            SELECT kf.entry_id, NULL AS kanji_id, kf.id AS kana_id,
                   NULL AS jpdb_rank, kf.wordfreq_zipf
            FROM kana_forms kf;

        CREATE INDEX idx_wf_entry_id ON word_frequency(entry_id);
        CREATE INDEX idx_wf_kana_id ON word_frequency(kana_id);
        CREATE INDEX idx_wf_kanji_id ON word_frequency(kanji_id);
        """
    )
    wf_count = conn.execute("SELECT COUNT(*) FROM word_frequency").fetchone()[0]
    print(f"  Done: {wf_count} word_frequency rows materialized")


def materialize_canonical_entry_ids(conn):
    # Materializes DictionaryStore.fetchCanonicalEntryIDMap's surface → canonical entry id
    # ranking (same selection priority as fetchMatchedEntries: functional/deictic POS first,
    # then kana-only, then jpdb/wordfreq rank, then sense order, then entry id) as a plain
    # indexed table instead of recomputing it at every app startup. The ranking is a pure
    # function of the dictionary data — it never depends on anything at runtime — so there's
    # no reason to pay its cost (a window function over a multi-way join across all ~450k
    # surfaces) on the user's device instead of once here. Must be run after word_frequency
    # and entry_functional_pos are materialized, and kept in exact lockstep with
    # DictionaryStore.FrequencySQL — see that Swift file for the shared-definition rationale.
    #
    # The functional/deictic POS boost is gated to pure-kana surfaces (IS_PURE_KANA below),
    # mirroring fetchMatchedEntries's `matchKana && !matchKanji` gate on the same tier
    # (DictionaryStore+RowFetching.swift): particles like が/の have archaic kanji forms
    # (我, 乃), so an entry's functional-POS tag must not promote it over the kanji word a
    # kanji-surface lookup (tapping 我 in text) clearly intended. Without this gate here, this
    # table would rank kanji surfaces differently than the live query does — exactly the drift
    # testCanonicalEntryIDMapAgreesWithLiveRankingForEveryAmbiguousSurface exists to catch.
    conn.create_function("IS_PURE_KANA", 1, lambda text: 1 if _is_pure_kana(text) else 0)

    print("Materializing surface_canonical_entry lookup table...")
    conn.executescript(
        """
        DROP TABLE IF EXISTS surface_canonical_entry;

        CREATE TABLE surface_canonical_entry (
            surface TEXT PRIMARY KEY,
            entry_id INTEGER NOT NULL
        );

        WITH surfaces_with_entries AS (
            SELECT text AS surface, entry_id FROM kanji
            UNION ALL
            SELECT text AS surface, entry_id FROM kana_forms
        ),
        m AS (
            SELECT s.surface, s.entry_id,
                   MIN(wf.jpdb_rank) AS rank,
                   MAX(wf.wordfreq_zipf) AS best_zipf,
                   EXISTS (SELECT 1 FROM kanji k WHERE k.entry_id = s.entry_id) AS has_kanji,
                   EXISTS (SELECT 1 FROM entry_functional_pos efp WHERE efp.entry_id = s.entry_id) AS is_functional,
                   COALESCE(MIN(sn.order_index), 2147483647) AS min_sense
            FROM surfaces_with_entries s
            LEFT JOIN word_frequency wf ON wf.entry_id = s.entry_id
                AND (EXISTS (SELECT 1 FROM kana_forms kf2 WHERE kf2.id = wf.kana_id AND kf2.text = s.surface)
                  OR EXISTS (SELECT 1 FROM kanji kj2 WHERE kj2.id = wf.kanji_id AND kj2.text = s.surface))
            LEFT JOIN senses sn ON sn.entry_id = s.entry_id
            GROUP BY s.surface, s.entry_id
        ),
        -- Adds a group-wide "does ANY entry sharing this surface have a real JPDB rank" signal
        -- (mirrors DictionaryStore.FrequencySQL.siblingRealRankTier). A kanji row's wordfreq_zipf
        -- is scored on the literal string, identically for every entry that writes it — it can't
        -- tell 日-the-common-noun (ひ, jpdb_rank 223) apart from 日-the-colloquial-counter-suffix
        -- (ち, no rank of its own), it's just repeating 日-the-character's overall corpus
        -- ubiquity. Without surface_best_rank below, that borrowed zipf fell into the pseudo-rank
        -- bucket table and numerically beat the noun's real rank.
        m2 AS (
            SELECT *, MIN(rank) OVER (PARTITION BY surface) AS surface_best_rank
            FROM m
        ),
        ranked AS (
            SELECT surface, entry_id,
                   ROW_NUMBER() OVER (
                       PARTITION BY surface
                       ORDER BY
                           CASE WHEN is_functional = 1 AND IS_PURE_KANA(surface) THEN 0 ELSE 1 END ASC,
                           has_kanji ASC,
                           -- Don't let a zipf pseudo-rank rescue this entry past a sibling (same
                           -- surface) that has a genuine rank; a no-op when nobody in the group
                           -- has any real rank (then everyone lands in tier 0, unchanged from
                           -- before, and the zipf-beats-a-weak-rank COALESCE below still applies).
                           CASE
                               WHEN rank IS NOT NULL THEN 0
                               WHEN surface_best_rank IS NOT NULL THEN 1
                               ELSE 0
                           END ASC,
                           COALESCE(
                               rank,
                               CASE
                                   WHEN best_zipf >= 7.0 THEN 5
                                   WHEN best_zipf >= 6.5 THEN 25
                                   WHEN best_zipf >= 6.0 THEN 100
                                   WHEN best_zipf >= 5.5 THEN 300
                                   WHEN best_zipf >= 5.0 THEN 1000
                                   WHEN best_zipf >= 4.5 THEN 3000
                                   WHEN best_zipf >= 4.0 THEN 10000
                                   WHEN best_zipf >= 3.5 THEN 30000
                                   WHEN best_zipf >= 3.0 THEN 100000
                                   ELSE 500000
                               END,
                               9999999
                           ) ASC,
                           min_sense ASC,
                           entry_id ASC
                   ) AS rn
            FROM m2
        )
        INSERT INTO surface_canonical_entry (surface, entry_id)
        SELECT surface, entry_id FROM ranked WHERE rn = 1;
        """
    )
    sce_count = conn.execute("SELECT COUNT(*) FROM surface_canonical_entry").fetchone()[0]
    print(f"  Done: {sce_count} surfaces mapped to a canonical entry id")


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

    total = time.time() - start
    print_phase_summary(total)
    print(f"Done in {total:.2f}s")
    print(f"Output: {OUTPUT_DB}")


if __name__ == "__main__":
    main()
