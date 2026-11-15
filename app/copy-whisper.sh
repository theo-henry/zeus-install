#!/bin/bash
# Copies whisper.framework (from the SwiftPM build) into the Frameworks folder of a Zeus.app, without its headers,
# module map, and debug symbols, which the app does not need at run time.
#
# Usage: app/copy-whisper.sh <path/to/whisper.framework> <Zeus.app/Contents/Frameworks>
set -euo pipefail
SOURCE="$1"
TARGET="$2/whisper.framework"
[ -f "$SOURCE/Versions/A/whisper" ] || { echo "whisper.framework is missing at $SOURCE" >&2; exit 1; }
rm -rf "$TARGET"
mkdir -p "$TARGET/Versions/A"
cp "$SOURCE/Versions/A/whisper" "$TARGET/Versions/A/whisper"
cp -R "$SOURCE/Versions/A/Resources" "$TARGET/Versions/A/Resources"
ln -s A "$TARGET/Versions/Current"
ln -s Versions/Current/whisper "$TARGET/whisper"
ln -s Versions/Current/Resources "$TARGET/Resources"
codesign --force --sign - "$TARGET" >/dev/null 2>&1
