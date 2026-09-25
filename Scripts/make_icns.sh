#!/bin/bash
# Generates the macOS .icns from the 1024px master artwork.
#   1. Scripts/make_icon.swift  → Assets/icon_1024.png (the drawn master)
#   2. sips resamples the full AppIcon.iconset size matrix
#   3. iconutil compiles Assets/Relay.icns
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Drawing 1024px master"
swift Scripts/make_icon.swift

ICONSET="Assets/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

echo "==> Resampling iconset"
for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do
    size="${spec%% *}"; name="${spec##* }"
    sips -z "$size" "$size" Assets/icon_1024.png --out "$ICONSET/$name.png" >/dev/null
done

echo "==> Compiling icns"
iconutil -c icns "$ICONSET" -o Assets/Relay.icns
echo "==> Done: Assets/Relay.icns"
