#!/bin/bash
# Generates the Relay Satellite .icns from its 1024px master artwork.
#   1. Scripts/make_satellite_icon.swift → Assets/satellite_1024.png
#   2. sips resamples the full AppIcon.iconset size matrix
#   3. iconutil compiles Assets/Satellite.icns
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Drawing 1024px Satellite master"
swift Scripts/make_satellite_icon.swift

ICONSET="Assets/SatelliteIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

echo "==> Resampling iconset"
for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do
    size="${spec%% *}"; name="${spec##* }"
    sips -z "$size" "$size" Assets/satellite_1024.png --out "$ICONSET/$name.png" >/dev/null
done

echo "==> Compiling icns"
iconutil -c icns "$ICONSET" -o Assets/Satellite.icns
echo "==> Done: Assets/Satellite.icns"
