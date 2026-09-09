#!/bin/bash
# Regenerates icon/AppIcon.icns from icon/AppIcon.svg. Needs rsvg-convert (brew install librsvg).
set -euo pipefail
cd "$(dirname "$0")"
rm -rf AppIcon.iconset && mkdir AppIcon.iconset
for s in 16 32 64 128 256 512 1024; do rsvg-convert -w $s -h $s AppIcon.svg -o "px_$s.png"; done
cp px_16.png   AppIcon.iconset/icon_16x16.png
cp px_32.png   AppIcon.iconset/icon_16x16@2x.png
cp px_32.png   AppIcon.iconset/icon_32x32.png
cp px_64.png   AppIcon.iconset/icon_32x32@2x.png
cp px_128.png  AppIcon.iconset/icon_128x128.png
cp px_256.png  AppIcon.iconset/icon_128x128@2x.png
cp px_256.png  AppIcon.iconset/icon_256x256.png
cp px_512.png  AppIcon.iconset/icon_256x256@2x.png
cp px_512.png  AppIcon.iconset/icon_512x512.png
cp px_1024.png AppIcon.iconset/icon_512x512@2x.png
rm -f px_*.png
iconutil -c icns AppIcon.iconset -o AppIcon.icns
echo "Wrote icon/AppIcon.icns — re-run ./build-app.sh to put it in the bundle."
