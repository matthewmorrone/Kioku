#!/bin/bash
# Copies one song's alignment dumps and cached vocal stem off the phone (Debug builds write the
# dumps on every alignment) into work/<dir>/, and decodes the stem to 44.1 kHz mono f32 for replay.
# Usage: pull.sh <stem key> [out dir name] [cues attachment UUID]
#   The key is in Documents/ctc-debug.log ("stem cache key=<key>.m4a") after aligning the song.
#   With an attachment UUID, also pulls Documents/audio/<UUID>.cues.json (the phone's saved result).
# Needs ffmpeg and a paired device; set KIOKU_DEVICE to override the device id.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
KEY="$1"; OUT="$HERE/work/${2:-phone}"; CUES="${3:-}"
DEV="${KIOKU_DEVICE:-00008150-00140DC10123C01C}"
mkdir -p "$OUT"
pull() { xcrun devicectl device copy from --device "$DEV" --domain-type appDataContainer \
    --domain-identifier matthewmorrone.Kioku --source "$1" --destination "$OUT/$(basename "$1")" > /dev/null; }
for f in emissions.f32 mix-emissions.f32 romaji.txt; do pull "Documents/ctc-debug/$KEY.$f"; done
pull "Library/Application Support/VocalStems/$KEY.m4a"
[ -n "$CUES" ] && pull "Documents/audio/$CUES.cues.json"
ffmpeg -hide_banner -loglevel error -y -i "$OUT/$KEY.m4a" -ac 1 -ar 44100 -f f32le "$OUT/$KEY.stem44.f32"
echo "pulled $KEY into $OUT"
