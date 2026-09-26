#!/bin/bash
# Builds Relay Satellite (the network receiver) into dist/Relay Satellite.app.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Relay Satellite"
BUNDLE_ID="app.relay.satellite"
APP_DIR="dist/${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"

echo "==> Generating app icon"
./Scripts/make_satellite_icns.sh >/dev/null

echo "==> swift build RelaySatellite (release)"
swift build -c release --product RelaySatellite

echo "==> Assembling ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"

cp .build/release/RelaySatellite "${CONTENTS}/MacOS/${APP_NAME}"
cp "Assets/Satellite.icns" "${CONTENTS}/Resources/AppIcon.icns"

cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>       <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>        <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>        <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>    <string>14.4</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "${CONTENTS}/PkgInfo"
codesign --force --sign - "${APP_DIR}"
echo "==> Done: ${APP_DIR}"
