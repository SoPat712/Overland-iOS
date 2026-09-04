#!/bin/bash
# Drive the running app over Facebook IDB: tabs, wifi zones, settings.
# Requires: idb_companion + idb CLI (brew install facebook/fb/idb-companion; pip3 install fb-idb)
set -euo pipefail

SIM="${SIM:-iPhone 17 Pro}"
BUNDLE_ID="com.aaronpk.overland"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
SHOTS="$DIR/screenshots"
mkdir -p "$SHOTS"

UDID=$(xcrun simctl list devices booted | grep "$SIM (" | grep -oE "[A-F0-9-]{36}" | head -1)
if [ -z "$UDID" ]; then
	echo "Boot $SIM first"; exit 1
fi

# Companion must outlive this script's parent shell
if ! pgrep -f "idb_companion --udid $UDID" > /dev/null; then
	setsid idb_companion --udid "$UDID" > /tmp/idb_companion.log 2>&1 < /dev/null &
	sleep 4
	idb connect localhost 10882 > /dev/null
fi

tab() { # tab tracker|trip|settings
	case "$1" in
		tracker)  idb ui tap 95 815 --udid "$UDID" ;;
		trip)     idb ui tap 201 815 --udid "$UDID" ;;
		settings) idb ui tap 286 815 --udid "$UDID" ;;
	esac
}
shot() { xcrun simctl io booted screenshot "$SHOTS/$1.png" 2>/dev/null; }

echo "Launching $BUNDLE_ID"
xcrun simctl terminate booted "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl launch booted "$BUNDLE_ID"
sleep 4

tab tracker; sleep 1; shot idb_tracker
tab trip; sleep 1; shot idb_trip
tab settings; sleep 1; shot idb_settings

echo "Done: $SHOTS/idb_*.png"
