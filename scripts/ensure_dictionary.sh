#!/usr/bin/env bash
# Decompress Resources/dictionary.sqlite from its committed .zst archive when
# missing or older than the archive. Idempotent — safe to run repeatedly,
# called from scripts/setup.sh for local clones and from the CI workflow.
#
# The sqlite is derived from generate_db.py + the upstream data files listed
# in data_manifest.json. Committing the .zst (~63 MB vs the raw 215 MB) keeps
# CI self-contained without paying LFS bandwidth.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SQLITE="$ROOT_DIR/Resources/dictionary.sqlite"
ARCHIVE="$ROOT_DIR/Resources/dictionary.sqlite.zst"

if [[ ! -f "$ARCHIVE" ]]; then
  echo "✗ Missing $ARCHIVE — repo state is incomplete." >&2
  exit 1
fi

# Skip if the decompressed file is already present and at least as recent as
# the archive. `! -ot` is "not older than" — true when newer OR equal mtime,
# which handles the freshly-decompressed case where zstd preserves the source
# mtime so the two files end up identical.
if [[ -f "$SQLITE" && ! "$SQLITE" -ot "$ARCHIVE" ]]; then
  exit 0
fi

if ! command -v zstd >/dev/null 2>&1; then
  echo "✗ zstd not installed. On macOS: brew install zstd. On Linux: apt install zstd." >&2
  exit 1
fi

echo "→ Decompressing dictionary.sqlite.zst → dictionary.sqlite"
zstd -d --force "$ARCHIVE" -o "$SQLITE"
# Bump mtime so subsequent invocations are silent even when zstd preserves
# the source timestamp.
touch "$SQLITE"
