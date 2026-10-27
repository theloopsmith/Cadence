#!/usr/bin/env bash
# Builds the Cadence Companion iOS app, boots an iPhone Simulator, installs and launches it.
# Build output goes to ~/Library/Caches (outside iCloud Drive) to avoid codesign xattr failures.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED="${CADENCE_XCODE_DERIVED:-$HOME/Library/Caches/CadenceBuild/xcode}"
BUNDLE_ID="com.theloopsmith.cadence.companion"
SIM_NAME="${CADENCE_SIM_NAME:-}"

# Pick the first available iPhone simulator unless one was specified.
if [ -z "$SIM_NAME" ]; then
  SIM_UDID="$(xcrun simctl list devices available | grep -E 'iPhone' | head -1 | grep -oE '[0-9A-F-]{36}')"
else
  SIM_UDID="$(xcrun simctl list devices available | grep -F "$SIM_NAME (" | head -1 | grep -oE '[0-9A-F-]{36}')"
fi
if [ -z "${SIM_UDID:-}" ]; then
  echo "No available iPhone simulator found. Install one via Xcode > Settings > Components." >&2
  exit 1
fi
echo "Using simulator $SIM_UDID"

echo "Building CadenceCompanionApp..."
xcodebuild \
  -project "$ROOT_DIR/ios/App/CadenceCompanionApp.xcodeproj" \
  -scheme CadenceCompanionApp \
  -configuration Debug \
  -destination "id=$SIM_UDID" \
  -derivedDataPath "$DERIVED" \
  -quiet \
  build

APP_PATH="$DERIVED/Build/Products/Debug-iphonesimulator/CadenceCompanionApp.app"

xcrun simctl boot "$SIM_UDID" 2>/dev/null || true
# Open the simulator GUI. Location varies by Xcode version
# (Simulator.app in older Xcodes; DeviceHub.app in Xcode 27+).
XCODE_APP="$(dirname "$(dirname "$(xcode-select -p)")")"
open -b com.apple.iphonesimulator 2>/dev/null \
  || open "$XCODE_APP/Contents/Developer/Applications/Simulator.app" 2>/dev/null \
  || open "$XCODE_APP/Contents/Applications/DeviceHub.app" 2>/dev/null \
  || echo "Could not open a simulator window automatically; the app will still be installed and launched."
xcrun simctl bootstatus "$SIM_UDID" -b >/dev/null

echo "Installing and launching..."
xcrun simctl install "$SIM_UDID" "$APP_PATH"
xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID"
echo "Cadence Companion is running in the Simulator."
