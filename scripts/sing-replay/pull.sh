#!/bin/bash
# Copies Sing sessions the phone's Debug build recorded (Documents/sing-debug/<stamp>/) into work/.
# Usage: pull.sh [stamp ...]   (no stamps: lists what's on the phone)
# Needs a paired device; set KIOKU_DEVICE to override the device id.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DEV="${KIOKU_DEVICE:-00008150-00140DC10123C01C}"
if [ $# -eq 0 ]; then
    xcrun devicectl device info files --device "$DEV" --domain-type appDataContainer \
        --domain-identifier matthewmorrone.Kioku --subdirectory Documents/sing-debug | grep session.json || true
    exit 0
fi
for stamp in "$@"; do
    mkdir -p "$HERE/work/$stamp"
    for f in session.json emissions.f32; do
        xcrun devicectl device copy from --device "$DEV" --domain-type appDataContainer \
            --domain-identifier matthewmorrone.Kioku --source "Documents/sing-debug/$stamp/$f" \
            --destination "$HERE/work/$stamp/$f" > /dev/null
    done
    echo "pulled $stamp into $HERE/work/$stamp"
done
