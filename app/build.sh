#!/bin/bash
# Builds Zeus.app (Apple silicon and Intel) and Zeus.zip in app/build.
# Needs only the Xcode Command Line Tools. The app gets an ad-hoc signature; no Developer ID is used.
#
# Usage: app/build.sh [version]     (default version: 0.1.0)
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$APP_DIR")"
VERSION="${1:-0.1.0}"
BUILD="$(git -C "$REPO_DIR" rev-list --count HEAD 2>/dev/null || echo 1)"
OUT="$APP_DIR/build"
BUNDLE="$OUT/Zeus.app"

cd "$APP_DIR"
rm -rf "$OUT"
mkdir -p "$OUT"

archs=(arm64 x86_64)
binaries=()
for arch in "${archs[@]}"; do
  swift build -c release --arch "$arch" --scratch-path "$OUT/.build-$arch" >&2
  binaries+=("$OUT/.build-$arch/$arch-apple-macosx/release/Zeus")
done

mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
lipo -create "${binaries[@]}" -output "$BUNDLE/Contents/MacOS/Zeus"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist >"$BUNDLE/Contents/Info.plist"
cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
# The app runs this copy of the installer, so the app and its installer always match.
cp "$REPO_DIR/install.sh" "$BUNDLE/Contents/Resources/install.sh"
printf 'APPL????' >"$BUNDLE/Contents/PkgInfo"

codesign --force --deep --sign - "$BUNDLE"
codesign --verify --strict "$BUNDLE"

# ditto keeps the bundle intact (signature, permissions) in the zip.
(cd "$OUT" && ditto -c -k --keepParent Zeus.app Zeus.zip)
rm -rf "$OUT"/.build-*
echo "$BUNDLE"
echo "$OUT/Zeus.zip"
