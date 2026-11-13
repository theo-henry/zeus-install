#!/bin/bash
# Development only: wraps the debug build in app/build/Zeus-dev.app (this Mac's architecture, ad-hoc signed).
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$APP_DIR"
swift build >&2
B="$APP_DIR/build/Zeus-dev.app"
rm -rf "$B"
mkdir -p "$B/Contents/MacOS" "$B/Contents/Resources"
cp .build/debug/Zeus "$B/Contents/MacOS/Zeus"
sed -e "s/__VERSION__/0.0.0-dev/" -e "s/__BUILD__/0/" Resources/Info.plist >"$B/Contents/Info.plist"
cp -R Resources/Terminal "$B/Contents/Resources/"
cp Resources/*.ttf "$B/Contents/Resources/"
cp Resources/*.woff "$B/Contents/Resources/"
cp Resources/zeus-logo.svg "$B/Contents/Resources/"
cp Resources/AppIcon.icns "$B/Contents/Resources/"
cp Resources/globe.js "$B/Contents/Resources/"
cp ../install.sh "$B/Contents/Resources/install.sh"
codesign --force --sign - --entitlements Resources/Zeus.entitlements "$B" 2>/dev/null
echo "$B"
