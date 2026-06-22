#!/usr/bin/env python3
# Build Resources/jlpt-vocab.tsv (the dictionary builder's JLPT input) from a
# Tanos-derived word→level CSV.
#
# Source data: Jonathan Waller's JLPT vocabulary lists (https://www.tanos.co.uk/jlpt/),
# licensed CC BY. This script consumes the cleaned, machine-readable CSV mirror from
# Bluskyo/JLPT_Vocabulary (MIT), file data/vocab/results/JLPT_vocab_ALL.csv, whose
# columns are: Kanji,Reading,Level — where Level is the N-number directly
# (5 = N5 easiest … 1 = N1 hardest).
#
# Output TSV columns: surface<TAB>reading<TAB>level (level kept as the N-number).
# Lossless apart from dropping blank/malformed rows; surface→entry matching and any
# junk filtering happen later in generate_db.import_jlpt_levels.
#
# Usage:
#   curl -sL https://raw.githubusercontent.com/Bluskyo/JLPT_Vocabulary/main/data/vocab/results/JLPT_vocab_ALL.csv -o /tmp/jlpt_all.csv
#   python3 scripts/build_jlpt_vocab_tsv.py /tmp/jlpt_all.csv
import csv
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DST = ROOT / "Resources" / "jlpt-vocab.tsv"
VALID_LEVELS = {"1", "2", "3", "4", "5"}


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit("usage: build_jlpt_vocab_tsv.py <JLPT_vocab_ALL.csv>")
    src = Path(sys.argv[1])
    if not src.exists():
        sys.exit(f"source CSV not found: {src}")

    rows = []
    with open(src, encoding="utf-8") as f:
        reader = csv.reader(f)
        next(reader, None)  # header: Kanji,Reading,Level
        for row in reader:
            if len(row) < 3:
                continue
            surface, reading, level = row[0].strip(), row[1].strip(), row[2].strip()
            if not surface or level not in VALID_LEVELS:
                continue
            rows.append((surface, reading, level))

    with open(DST, "w", encoding="utf-8") as f:
        f.write("surface\treading\tlevel\n")
        for surface, reading, level in rows:
            f.write(f"{surface}\t{reading}\t{level}\n")

    print(f"Wrote {len(rows)} rows -> {DST.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
