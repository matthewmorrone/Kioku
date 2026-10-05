#!/usr/bin/env bash
# Publishes Resources/dictionary.sqlite to the GitHub Release pinned in
# DictionaryDownloadManager.swift, as two assets: the raw dictionary.sqlite
# (downloaded by scripts/ensure_dictionary.sh and CI) and dictionary.sqlite.xz
# (downloaded by the app, a quarter of the size; expectedSHA256 pins the
# uncompressed bytes, which the app checks after unpacking). Run this locally after regenerating the
# dictionary (Resources/generate_db.py) and bumping releaseTag/expectedSHA256
# to a new tag. Publish the exact file you checked: a rebuild fetches upstream
# afresh and can differ, and the database records which upstream bytes it was
# built from (build_sources / build_info), which the release notes list.
#
# With --dev, publishes to the moving dictionary-dev release instead (see below).
#
# Requires: `gh` CLI authenticated with a token that can create releases on
# this repo (`gh auth status` to check).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SQLITE="$ROOT_DIR/Resources/dictionary.sqlite"
PIN_SOURCE="$ROOT_DIR/Kioku/Dictionary/DictionaryDownloadManager.swift"
REPO="matthewmorrone/Kioku"
ARCHIVE="$ROOT_DIR/Resources/dictionary.sqlite.xz"

NOTES="$ROOT_DIR/Resources/dictionary-release-notes.md"

# --dev [path]: overwrite the moving dictionary-dev release that debug builds follow
# (DictionaryDownloadManager.devChannelTag) with the given database (default Resources/dictionary.sqlite).
# No pin, no version bump: the app compares dictionary.sqlite.sha256 with what it has and re-downloads
# when they differ. The pinned release only moves when an App Store build ships.
if [[ "${1:-}" == "--dev" ]]; then
  DEV_SQLITE="${2:-$SQLITE}"
  DEV_DIR="$(mktemp -d)"
  trap 'rm -rf "$DEV_DIR"' EXIT
  echo "→ Compressing $DEV_SQLITE"
  shasum -a 256 "$DEV_SQLITE" | awk '{print $1}' > "$DEV_DIR/dictionary.sqlite.sha256"
  xz -6 -T0 -k -c "$DEV_SQLITE" > "$DEV_DIR/dictionary.sqlite.xz"
  if ! gh release view dictionary-dev --repo "$REPO" > /dev/null 2>&1; then
    gh release create dictionary-dev --repo "$REPO" --prerelease --title dictionary-dev \
      --notes "Development dictionary for debug builds of Kioku; overwritten on every publish."
  fi
  gh release upload dictionary-dev "$DEV_DIR/dictionary.sqlite.xz" "$DEV_DIR/dictionary.sqlite.sha256" --repo "$REPO" --clobber
  echo "✓ dictionary-dev now serves $(cat "$DEV_DIR/dictionary.sqlite.sha256")"
  exit 0
fi

# Writes the release notes: the checksum pin, the database's license (a compilation of CC BY-SA
# sources is CC BY-SA 4.0 as a whole), every source that feeds it with its license (read from
# data-manifest.json so the credits can't drift from the build), exactly which upstream bytes and
# tools it was built from (the database's build_sources / build_info tables), and UniDic's BSD
# notice, which BSD-3-Clause requires to accompany binary redistribution.
write_notes() {
  python3 - "$ROOT_DIR/Resources/data-manifest.json" "$EXPECTED_SHA256" "$SQLITE" > "$NOTES" <<'PY'
import json, sqlite3, sys
manifest = json.load(open(sys.argv[1], encoding="utf-8"))
print(f"sha256 (uncompressed dictionary.sqlite): {sys.argv[2]}")
print()
print("dictionary.sqlite.xz is the same database, xz-compressed; it is what the Kioku app downloads.")
print()
print("## License")
print()
print("This database is a compilation that adapts the CC BY-SA sources below, so it is distributed "
      "under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). Each source keeps its own license:")
print()
for r in manifest["resources"]:
    if r.get("feedsDictionary") and not r.get("derived"):
        print(f"- **{r['name']}**: {r.get('license', 'license not recorded')}")
print()
db = sqlite3.connect(f"file:{sys.argv[3]}?mode=ro", uri=True)
tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
if "build_sources" in tables:
    print("## Sources used")
    print()
    print("| Source | Upstream edition | Fetched (UTC) | sha256 | Pinned |")
    print("|---|---|---|---|---|")
    for name, version, modified, fetched, digest, pinned in db.execute(
            "SELECT name, upstream_version, last_modified, fetched_at, sha256, pinned FROM build_sources ORDER BY name"):
        print(f"| {name} | {version or modified or '-'} | {fetched} | `{digest}` | {'yes' if pinned else 'no'} |")
    print()
    print("Built with: " + ", ".join(f"{k} {v}" for k, v in db.execute(
        "SELECT key, value FROM build_info WHERE key IN ('git_commit', 'python', 'wordfreq', 'mecab', 'built_at') ORDER BY key")))
    print()
print("UniDic data is used under its BSD-3-Clause option:")
print()
PY
  sed 's/^/    /' "$ROOT_DIR/Kioku/Settings/Licenses/UniDic-BSD.txt" >> "$NOTES"
}

# Writes dictionary.sqlite.xz beside the sqlite and proves it round-trips to the pinned bytes before
# anything is uploaded. xz -6 is the preset Apple's Compression framework decodes as `.lzma`.
build_archive() {
  echo "→ Compressing $SQLITE → $(basename "$ARCHIVE")"
  xz -6 -T0 -k -c "$SQLITE" > "$ARCHIVE"
  local roundtrip
  roundtrip=$(xz -d -c "$ARCHIVE" | shasum -a 256 | awk '{print $1}')
  if [[ "$roundtrip" != "$EXPECTED_SHA256" ]]; then
    echo "✗ $(basename "$ARCHIVE") does not decompress to the pinned bytes ($roundtrip)." >&2
    exit 1
  fi
}

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
  # Release JSON (including its editable body) is fed on stdin and parsed as data — never
  # interpolated into the Python source, where release text could break out and run as code.
  PUBLISHED_DIGEST=$(printf '%s' "$EXISTING_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
matches = [a.get('digest') for a in data['assets'] if a['name'] == 'dictionary.sqlite']
print(matches[0] if matches else '')
")
  if [[ "$PUBLISHED_DIGEST" != "sha256:$EXPECTED_SHA256" ]]; then
    echo "✗ Release $RELEASE_TAG already exists but its dictionary.sqlite digest ($PUBLISHED_DIGEST) doesn't match the pin (sha256:$EXPECTED_SHA256)." >&2
    echo "  Release tags must never be reused for different content — bump releaseTag to a new tag instead." >&2
    exit 1
  fi
  # Releases published before the app switched to the archive only carry the raw sqlite. Adding
  # the archive leaves the pinned bytes untouched, so it doesn't count as reusing the tag.
  HAS_ARCHIVE=$(printf '%s' "$EXISTING_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print('yes' if any(a['name'] == 'dictionary.sqlite.xz' for a in data['assets']) else 'no')
")
  # Notes are regenerated on every run so an existing release picks up credit corrections.
  write_notes
  gh release edit "$RELEASE_TAG" --repo "$REPO" --notes-file "$NOTES"
  if [[ "$HAS_ARCHIVE" == "yes" ]]; then
    echo "✓ Release $RELEASE_TAG already exists with both assets and a matching digest — notes refreshed."
    exit 0
  fi
  build_archive
  echo "→ Adding $(basename "$ARCHIVE") to existing release $RELEASE_TAG"
  gh release upload "$RELEASE_TAG" "$ARCHIVE" --repo "$REPO"
  echo "✓ Added $(basename "$ARCHIVE") to $RELEASE_TAG."
  exit 0
fi

# Refuse to publish a dictionary that predates extras.json. The pin hash only proves these are the
# bytes someone intended to ship, not that they were regenerated after the last lexicon edit —
# dictionary-v8 was built before ユア was added to extras.json in the same commit, so the entry its
# own release notes describe was never in the file. Every extras surface must be present.
MISSING_EXTRAS=$(python3 - "$ROOT_DIR/Resources/extras.json" "$SQLITE" <<'PY'
import json, sqlite3, sys
extras = json.load(open(sys.argv[1], encoding="utf-8"))
conn = sqlite3.connect(sys.argv[2])
known = {text for (text,) in conn.execute("SELECT text FROM kana_forms UNION SELECT text FROM kanji")}
missing = []
for entry in extras.get("entries", []):
    for field in ("kana", "kanji"):
        value = entry.get(field)
        for item in value if isinstance(value, list) else [value]:
            text = item.get("text") if isinstance(item, dict) else item
            if isinstance(text, str) and text and text not in known:
                missing.append(text)
print(" ".join(missing))
PY
)
if [[ -n "$MISSING_EXTRAS" ]]; then
  echo "✗ $SQLITE is missing extras.json entries: $MISSING_EXTRAS" >&2
  echo "  It was built before extras.json last changed — rerun Resources/generate_db.py, then re-pin." >&2
  exit 1
fi

build_archive
write_notes
echo "→ Publishing $RELEASE_TAG ($ACTUAL_SHA256)"
gh release create "$RELEASE_TAG" "$SQLITE" "$ARCHIVE" \
  --repo "$REPO" \
  --title "$RELEASE_TAG" \
  --notes-file "$NOTES"
echo "✓ Published $RELEASE_TAG."
