#!/bin/bash
# Build, install and launch on one explicitly selected simulator.
set -euo pipefail

APP_PATH="${1:-}"
SIM="${SIM:-iPhone 17 Pro}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
SHOTS="$DIR/Screenshots"
DERIVED_DATA="${DERIVED_DATA:-/tmp/overland-smoke-build}"
mkdir -p "$SHOTS"

UDID=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; name=sys.argv[1]; print(next(d["udid"] for devices in json.load(sys.stdin)["devices"].values() for d in devices if d["name"] == name))' "$SIM")
STATE=$(xcrun simctl list devices -j | python3 -c 'import json,sys; udid=sys.argv[1]; print(next(d["state"] for devices in json.load(sys.stdin)["devices"].values() for d in devices if d["udid"] == udid))' "$UDID")
if [ "$STATE" != "Booted" ]; then
    xcrun simctl boot "$UDID"
fi
xcrun simctl bootstatus "$UDID" -b

if [ -z "$APP_PATH" ]; then
    xcodebuild -workspace "$DIR/Overland.xcworkspace" -scheme Overland \
        -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DERIVED_DATA" build
    APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/Overland.app"
fi

xcrun simctl install "$UDID" "$APP_PATH"
xcrun simctl terminate "$UDID" com.aaronpk.overland 2>/dev/null || true
xcrun simctl launch "$UDID" com.aaronpk.overland
sleep 3
xcrun simctl io "$UDID" screenshot "$SHOTS/smoke_1_launch.png"
echo "Launch smoke check complete. Run idb_ui_test.sh for UI assertions."
