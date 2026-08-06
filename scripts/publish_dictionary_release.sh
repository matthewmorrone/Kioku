#!/usr/bin/env bash
# Publishes Resources/dictionary.sqlite to the GitHub Release pinned in
# DictionaryDownloadManager.swift. Run this locally after regenerating the
# dictionary (Resources/generate_db.py) and bumping releaseTag/expectedSHA256
# to a new tag — never in CI: generate_db.py's upstream inputs (JMDict,
# KANJIDIC, JPDB frequency data, etc.) are gitignored, so only whichever
# machine actually ran the generator has the correct bytes to publish.
#
# Requires: `gh` CLI authenticated with a token that can create releases on
# this repo (`gh auth status` to check).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SQLITE="$ROOT_DIR/Resources/dictionary.sqlite"
PIN_SOURCE="$ROOT_DIR/Kioku/Dictionary/DictionaryDownloadManager.swift"
REPO="matthewmorrone/Kioku"

if [[ ! -f "$SQLITE" ]]; then
  echo "✗ $SQLITE not found — run Resources/generate_db.py first." >&2
  exit 1
fi

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

# Guards against publishing the wrong bytes under the right tag: if the local
# rebuild doesn't match the pin, the pin wasn't bumped (or the rebuild is
# stale) — fix that before anything is released, not after.
ACTUAL_SHA256=$(shasum -a 256 "$SQLITE" | awk '{print $1}')
if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
  echo "✗ $SQLITE has sha256 $ACTUAL_SHA256, but DictionaryDownloadManager.expectedSHA256 says $EXPECTED_SHA256." >&2
  echo "  Bump releaseTag/expectedSHA256 in DictionaryDownloadManager.swift to $ACTUAL_SHA256 (and a new tag) before publishing." >&2
  exit 1
fi

# Tags are treated as immutable once published (see DictionaryDownloadManager's
# own comment: "Pinned to a specific release tag, not a moving tag") — every
# installed app's cached checksum assumption depends on a tag's content never
# changing after the fact. Uses the release-asset API's own `digest` field so
# this doesn't need to download the ~350MB asset just to check it.
if EXISTING_JSON=$(gh api "repos/$REPO/releases/tags/$RELEASE_TAG" 2>/dev/null); then
  PUBLISHED_DIGEST=$(python3 -c "
import json
data = json.loads('''$EXISTING_JSON''')
matches = [a.get('digest') for a in data['assets'] if a['name'] == 'dictionary.sqlite']
print(matches[0] if matches else '')
")
  if [[ "$PUBLISHED_DIGEST" != "sha256:$EXPECTED_SHA256" ]]; then
    echo "✗ Release $RELEASE_TAG already exists but its dictionary.sqlite digest ($PUBLISHED_DIGEST) doesn't match the pin (sha256:$EXPECTED_SHA256)." >&2
    echo "  Release tags must never be reused for different content — bump releaseTag to a new tag instead." >&2
    exit 1
  fi
  echo "✓ Release $RELEASE_TAG already exists and its asset digest matches — nothing to publish."
  exit 0
fi

echo "→ Publishing $RELEASE_TAG ($ACTUAL_SHA256)"
gh release create "$RELEASE_TAG" "$SQLITE" \
  --repo "$REPO" \
  --title "$RELEASE_TAG" \
  --notes "sha256: $EXPECTED_SHA256"
echo "✓ Published $RELEASE_TAG."
