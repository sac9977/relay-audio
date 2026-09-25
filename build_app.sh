#!/bin/bash
# Builds Relay and assembles a double-clickable Relay.app bundle.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Relay"
BUNDLE_ID="app.relay"
BUILD_DIR=".build"
APP_DIR="dist/${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"

echo "==> Generating app icon"
./Scripts/make_icns.sh >/dev/null

echo "==> swift build (release)"
swift build -c release

BINARY="${BUILD_DIR}/release/${APP_NAME}"
echo "==> Assembling ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"

cp "${BINARY}" "${CONTENTS}/MacOS/${APP_NAME}"
cp "Assets/Relay.icns" "${CONTENTS}/Resources/AppIcon.icns"

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
    <key>LSApplicationCategoryType</key> <string>public.app-category.music</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
    <key>LSUIElement</key>               <false/>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Relay captures the audio of the app you choose so it can be played on other speakers around your home. Audio is only used for playback you request and is never stored or sent anywhere without your action.</string>
</dict>
</plist>
PLIST

cat > "${APP_DIR}/Contents/PkgInfo" <<'PKGIN'
APPL????
PKGIN

# Keep the MenuBarExtra's auto-generated window findable by id.
cat > "${CONTENTS}/Resources/Relay.storyboardc" <<'EOF' 2>/dev/null || true
EOF
rm -f "${CONTENTS}/Resources/Relay.storyboardc"

echo "==> Ad-hoc code signing"
codesign --force --deep --sign - "${APP_DIR}"
touch "${APP_DIR}"

echo "==> Done: ${APP_DIR}"
echo "    Run: open ${APP_DIR}"
