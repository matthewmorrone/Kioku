#!/usr/bin/env bash
# Downloads Resources/dictionary.sqlite from the GitHub Release pinned in
# DictionaryDownloadManager.swift when missing or doesn't match that pin.
# Idempotent — safe to run repeatedly, called from scripts/setup.sh for local
# clones and from the CI workflow.
#
# The sqlite is derived from generate_db.py + upstream data files that aren't
# committed to this repo (see data-manifest.json for where to get them), so
# this script can't regenerate it — only a developer with those raw inputs
# locally can. Previously the compressed sqlite was committed directly to git
# (split into <100MB parts) and reassembled here; every rebuild added a new
# ~150MB blob that never diff-compresses against the last one, growing the
# repo (and GitHub's storage of it) without bound. The GitHub Release
# DictionaryDownloadManager downloads at runtime is now the one source of
# truth here too, so nothing but this script and the small pin in
# DictionaryDownloadManager.swift needs to be tracked in git.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SQLITE="$ROOT_DIR/Resources/dictionary.sqlite"
PIN_SOURCE="$ROOT_DIR/Kioku/Dictionary/DictionaryDownloadManager.swift"

RELEASE_TAG=$(python3 -c "
import re
text = open('$PIN_SOURCE').read()
m = re.search(r'releaseTag = \"([^\"]+)\"', text)
print(m.group(1) if m else '')
")
EXPECTED_SHA256=$(python3 -c "
import re
text = open('$PIN_SOURCE').read()
m = re.search(r'expectedSHA256 = \"([^\"]+)\"', text)
print(m.group(1) if m else '')
")

if [[ -z "$RELEASE_TAG" || -z "$EXPECTED_SHA256" ]]; then
  echo "✗ Could not parse releaseTag/expectedSHA256 out of DictionaryDownloadManager.swift — has its source shape changed?" >&2
  exit 1
fi

# Skip the download entirely when an already-correct file is sitting there —
# the common case for repeat local builds and warm CI caches.
if [[ -f "$SQLITE" ]]; then
  ACTUAL_SHA256=$(shasum -a 256 "$SQLITE" | awk '{print $1}')
  if [[ "$ACTUAL_SHA256" == "$EXPECTED_SHA256" ]]; then
    exit 0
  fi
fi

URL="https://github.com/matthewmorrone/Kioku/releases/download/$RELEASE_TAG/dictionary.sqlite"
echo "→ Downloading dictionary.sqlite from $URL"
curl -fL --retry 3 -o "$SQLITE.download" "$URL"

# Verify before installing — a corrupt download or a tag that's drifted from
# the pin must not silently become the app's dictionary.
ACTUAL_SHA256=$(shasum -a 256 "$SQLITE.download" | awk '{print $1}')
if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
  rm -f "$SQLITE.download"
  echo "✗ Downloaded dictionary.sqlite sha256 ($ACTUAL_SHA256) doesn't match DictionaryDownloadManager.expectedSHA256 ($EXPECTED_SHA256)." >&2
  exit 1
fi

mv "$SQLITE.download" "$SQLITE"
echo "✓ dictionary.sqlite downloaded and verified ($RELEASE_TAG)."
