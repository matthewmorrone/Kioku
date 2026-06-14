#!/usr/bin/env bash
# Decompress Resources/dictionary.sqlite from its committed zstd archive when
# missing or older than the archive. Idempotent — safe to run repeatedly,
# called from scripts/setup.sh for local clones and from the CI workflow.
#
# The sqlite is derived from generate_db.py + the upstream data files listed
# in data_manifest.json. Committing the compressed archive keeps CI self-contained
# without paying LFS bandwidth. The archive is split into ~52 MB parts
# (dictionary.sqlite.zst.part-aa, -ab, …) because the single .zst exceeds
# GitHub's 100 MB per-file push limit; the parts are concatenated back before
# decompression.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SQLITE="$ROOT_DIR/Resources/dictionary.sqlite"
PART_GLOB="$ROOT_DIR/Resources/dictionary.sqlite.zst.part-"*
# A representative part for the staleness comparison (git checkout gives the
# parts a uniform mtime, so any one of them is a fine reference point).
FIRST_PART="$ROOT_DIR/Resources/dictionary.sqlite.zst.part-aa"

if [[ ! -f "$FIRST_PART" ]]; then
  echo "✗ Missing dictionary archive parts (Resources/dictionary.sqlite.zst.part-*) — repo state is incomplete." >&2
  exit 1
fi

# Skip if the decompressed file is already present and at least as recent as
# the archive parts. `! -ot` is "not older than" — true when newer OR equal
# mtime, which handles the freshly-decompressed case.
if [[ -f "$SQLITE" && ! "$SQLITE" -ot "$FIRST_PART" ]]; then
  exit 0
fi

if ! command -v zstd >/dev/null 2>&1; then
  echo "✗ zstd not installed. On macOS: brew install zstd. On Linux: apt install zstd." >&2
  exit 1
fi

echo "→ Concatenating dictionary.sqlite.zst.part-* and decompressing → dictionary.sqlite"
# Reassemble the parts (glob expands in sorted order: -aa, -ab, -ac) and stream
# straight into the decompressor so no full-size intermediate .zst is written.
cat $PART_GLOB | zstd -dc > "$SQLITE"
# Bump mtime so subsequent invocations are silent even when zstd preserves
# the source timestamp.
touch "$SQLITE"
