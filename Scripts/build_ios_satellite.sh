#!/bin/bash
# Builds the iOS Relay Satellite receiver app for the iOS Simulator and
# (optionally) installs + launches it on a booted simulator.
#
#   ./Scripts/build_ios_satellite.sh            # build dist/RelaySatelliteIOS.app
#   ./Scripts/build_ios_satellite.sh --install  # + install & launch on booted sim
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Relay Satellite"
BUNDLE_ID="app.relay.satellite.ios"
APP_DIR="dist/RelaySatelliteIOS.app"
CONTENTS="${APP_DIR}"

echo "==> swift build RelaySatelliteIOS (iphonesimulator)"
xcrun swift build --product RelaySatelliteIOS --swift-sdk arm64-apple-ios17.0-simulator

BINARY=$(find .build -path "*iphonesimulator*" -name RelaySatelliteIOS -type f 2>/dev/null | head -1)
if [ -z "$BINARY" ]; then
    echo "ERROR: simulator binary not found" >&2
    exit 1
fi

echo "==> Assembling ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}"

cp "$BINARY" "${APP_DIR}/${APP_NAME}"

cat > "${APP_DIR}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>               <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>        <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>         <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>         <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleVersion</key>            <string>1</string>
    <key>LSRequiresIPhoneOS</key>         <true/>
    <key>MinimumOSVersion</key>           <string>17.0</string>
    <key>UILaunchScreen</key>             <dict/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Relay Satellite receives lossless audio from Relay on your network and announces itself so Relay can find it automatically.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_relay-sat._udp</string>
    </array>
</dict>
</plist>
PLIST

printf 'APPL????' > "${APP_DIR}/PkgInfo"

codesign --force --sign - "${APP_DIR}"
echo "==> Done: ${APP_DIR}"

if [ "${1:-}" = "--install" ]; then
    echo "==> Installing on booted simulator"
    xcrun simctl boot "iPhone 17 Pro" 2>/dev/null || true
    xcrun simctl install booted "${APP_DIR}"
    echo "==> Launching ${BUNDLE_ID}"
    xcrun simctl launch booted "${BUNDLE_ID}"
fi
