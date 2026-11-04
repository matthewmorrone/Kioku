#!/bin/bash
# Builds work/sing-replay from this repo's Sing grading sources, so a replay is the shipped code.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../../LyricAlignment/Sources/LyricAlignment"
mkdir -p "$HERE/work"
swiftc -O -swift-version 5 "$HERE/main.swift" "$HERE/stubs.swift" \
    "$SRC"/{SingInOrderGrader,SingEmissionTimeline,SingPhonemeScorer,SingHeardDecoder,SingWordTarget,CTCEmissions,RomajiPhonemes}.swift \
    -o "$HERE/work/sing-replay"
echo "built $HERE/work/sing-replay"
