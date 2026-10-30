#!/bin/bash
# Copies the temporary audio debug log off the iPhone into Debug/AudioLogs/<time>/
# and prints a summary of the runs in it. See Learn2Sing/Sources/Debug/AudioDebugLog.swift.
#
#   Tools/AudioDebugLog/pull_audio_logs.sh [device]
#
# `device` is a devicectl identifier, UDID or device name; without it, the first
# paired iPhone. Works over Wi-Fi as well as the cable. The system log, which holds
# the AirPods' own delay reports, needs the cable and sudo; the command for it is
# printed at the end.
set -euo pipefail
cd "$(dirname "$0")/../.."

LIST=$(mktemp)
trap 'rm -f "$LIST"' EXIT
xcrun devicectl list devices --json-output "$LIST" >/dev/null 2>&1
read -r DEVICE UDID < <(python3 -I -c '
import json, sys
wanted = sys.argv[2]
devices = json.load(open(sys.argv[1]))["result"]["devices"]
def matches(d):
    if not wanted:
        return d.get("hardwareProperties", {}).get("deviceType") == "iPhone"
    return wanted in (d.get("identifier"), d.get("hardwareProperties", {}).get("udid"),
                      d.get("deviceProperties", {}).get("name"))
found = [d for d in devices if matches(d)]
if found:
    print(found[0]["identifier"], found[0].get("hardwareProperties", {}).get("udid", "<udid>"))
' "$LIST" "${1:-}")
if [ -z "${DEVICE:-}" ]; then
    echo "No paired iPhone found (xcrun devicectl list devices)." >&2
    exit 1
fi

DEST="Debug/AudioLogs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$DEST"
echo "Copying from $DEVICE to $DEST"
xcrun devicectl device copy from --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier CDE.Learn2Singg --user mobile \
    --source "Library/Application Support/AudioDebugLog" --destination "$DEST" --quiet
# devicectl may put a folder it copies inside the destination under its own name.
if [ -d "$DEST/AudioDebugLog" ]; then
    mv "$DEST/AudioDebugLog"/* "$DEST"/ && rmdir "$DEST/AudioDebugLog"
fi

python3 -I Tools/AudioDebugLog/summarize_audio_logs.py "$DEST"

echo
echo "System log (cable and sudo; bluetoothd keeps a few hours, audiomxd only minutes):"
echo "  sudo log collect --device-udid $UDID --start '$(date -v-6H '+%Y-%m-%d %H:%M:%S')' --output $DEST/system.logarchive && sudo chown -R $USER $DEST/system.logarchive"
