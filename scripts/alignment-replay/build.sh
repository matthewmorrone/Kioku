#!/bin/bash
# Builds work/replay from this repo's aligner sources, so a replay is the shipped pipeline.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../../SwiftWhisperAlign/Sources/SwiftWhisperAlign"
mkdir -p "$HERE/work"
swiftc -O -swift-version 5 "$HERE/replay/main.swift" "$HERE/replay/stubs.swift" \
    "$SRC"/{CTCAlignmentCore,RepeatedLineSpreader,CTCViterbi,EmissionDropoutFill,EnergyVAD,MMSEmissions,Models}.swift \
    -o "$HERE/work/replay"
echo "built $HERE/work/replay"
