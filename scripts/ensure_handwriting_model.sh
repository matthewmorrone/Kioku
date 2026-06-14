#!/usr/bin/env bash
# Decompress Resources/handwriting-ja.model from its committed .zst archive when
# missing or older than the archive. Idempotent — safe to run repeatedly,
# called from scripts/setup.sh for local clones and from the CI workflow.
#
# The model is a binary Zinnia handwriting-recognition asset copied into the app
# bundle (Copy Bundle Resources). Committing the .zst (~14 MB vs the raw 25 MB)
# keeps CI self-contained — the raw .model is gitignored — without paying LFS
# bandwidth, mirroring how dictionary.sqlite is provisioned.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL="$ROOT_DIR/Resources/handwriting-ja.model"
ARCHIVE="$ROOT_DIR/Resources/handwriting-ja.model.zst"

if [[ ! -f "$ARCHIVE" ]]; then
  echo "✗ Missing $ARCHIVE — repo state is incomplete." >&2
  exit 1
fi

# Skip if the decompressed file is already present and at least as recent as
# the archive. `! -ot` is "not older than" — true when newer OR equal mtime,
# which handles the freshly-decompressed case where zstd preserves the source
# mtime so the two files end up identical.
if [[ -f "$MODEL" && ! "$MODEL" -ot "$ARCHIVE" ]]; then
  exit 0
fi

if ! command -v zstd >/dev/null 2>&1; then
  echo "✗ zstd not installed. On macOS: brew install zstd. On Linux: apt install zstd." >&2
  exit 1
fi

echo "→ Decompressing handwriting-ja.model.zst → handwriting-ja.model"
zstd -d --force "$ARCHIVE" -o "$MODEL"
# Bump mtime so subsequent invocations are silent even when zstd preserves
# the source timestamp.
touch "$MODEL"
