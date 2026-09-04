#!/bin/bash
# Build, install, launch and smoke-test Overland on the booted simulator.
# Usage: ./ci_scripts/smoke_test.sh [app-bundle-path]
set -euo pipefail

APP_PATH="${1:-}"
SCHEME="Overland"
SIM="iPhone 17 Pro"
BUNDLE_ID="com.aaronpk.overland"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
SHOTS="$DIR/screenshots"
mkdir -p "$SHOTS"

if [ -z "$APP_PATH" ]; then
	echo "Building..."
	xcodebuild -workspace "$DIR/Overland.xcworkspace" -scheme "$SCHEME" \
		-destination "platform=iOS Simulator,name=$SIM" build | tail -1
	APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/Overland-*/Build/Products/Debug-iphonesimulator -name "Overland.app" -maxdepth 1 | head -1)
fi

UDID=$(xcrun simctl list devices booted | grep "$SIM (" | grep -oE "[A-F0-9-]{36}" | head -1)
if [ -z "$UDID" ]; then
	xcrun simctl boot "$SIM"
	xcrun simctl bootstatus "$SIM" -b
	UDID=$(xcrun simctl list devices booted | grep "$SIM (" | grep -oE "[A-F0-9-]{36}" | head -1)
fi

xcrun simctl install booted "$APP_PATH"
xcrun simctl launch booted "$BUNDLE_ID"
sleep 4
xcrun simctl io booted screenshot "$SHOTS/smoke_1_launch.png" 2>/dev/null

# Simulate a location and confirm the UI picks it up
xcrun simctl location booted set 45.5152,-122.6784
sleep 5
xcrun simctl io booted screenshot "$SHOTS/smoke_2_location.png" 2>/dev/null

echo "Smoke test complete: $SHOTS/smoke_*.png"
