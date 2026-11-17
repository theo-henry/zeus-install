#!/bin/bash
# A release build ignores the debug settings: started with ZEUS_APP_TRACE and ZEUS_EDITOR_STATE_DIR, it writes no
# trace file and makes no editor state folder there. The debug build, started the same way, writes the trace file, so
# the test shows that the settings reach the app.
#
# Each build is wrapped as app/dev-bundle.sh does (this Mac's architecture), with version 9.9.9 (not a development
# version) and a test bundle identifier, and starts from <temporary home>/Applications, so that it does not move
# itself. It starts in the background (open -g -j) and as a background-only app, so that it stays behind other windows.
#
# Usage: app/test/release-env/run.sh
set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$TEST_DIR/../.." && pwd)"
BUNDLE_ID="io.github.theo-henry.zeus.test-release-env"
# The time that the app runs before the test stops it.
RUN_SECONDS="${ZEUS_RELEASE_ENV_TEST_SECONDS:-10}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/zeus-release-env.XXXXXX")"
TAG="$(basename "$WORK")"

FAILURES=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

# macOS can start the app from /private/var or from /var, so the pattern names only the test folder.
stop_app() {
  pkill -f "/$TAG/[^/]*/Applications/Zeus.app/Contents/MacOS/Zeus" 2>/dev/null || true
  sleep 1
  pkill -9 -f "/$TAG/[^/]*/Applications/Zeus.app/Contents/MacOS/Zeus" 2>/dev/null || true
}
cleanup() {
  stop_app
  rm -rf "$WORK"
  defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  rm -rf "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
}
trap cleanup EXIT

# The app takes its folder with the links resolved (Foundation shows /private/var as /var). The temporary home must
# have that form: in another form, the app does not see that it is in <home>/Applications, and moves itself to
# /Applications, over the user's app.
cat >"$WORK/resolve.swift" <<'SWIFT'
import Foundation
print(URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.resolvingSymlinksInPath().path)
SWIFT
swiftc -o "$WORK/resolve" "$WORK/resolve.swift" 2>/dev/null
WORK="$("$WORK/resolve" "$WORK")"
# The user's app in /Applications: the test must not change it.
user_app_state() { stat -f '%i %m' /Applications/Zeus.app 2>/dev/null || echo none; }
USER_APP_BEFORE="$(user_app_state)"

# bundle <debug|release> <home>: builds the app and wraps it in <home>/Applications/Zeus.app.
bundle() {
  local config="$1" home="$2" products app
  (cd "$APP_DIR" && swift build -c "$config" >&2)
  products="$(cd "$APP_DIR" && swift build -c "$config" --show-bin-path)"
  app="$home/Applications/Zeus.app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
  cp "$products/Zeus" "$app/Contents/MacOS/Zeus"
  "$APP_DIR/copy-whisper.sh" "$products/whisper.framework" "$app/Contents/Frameworks"
  sed -e "s/__VERSION__/9.9.9/" -e "s/__BUILD__/0/" "$APP_DIR/Resources/Info.plist" >"$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" -c "Add :LSBackgroundOnly bool true" "$app/Contents/Info.plist"
  cp -R "$APP_DIR/Resources/Terminal" "$app/Contents/Resources/"
  cp "$APP_DIR"/Resources/*.ttf "$APP_DIR"/Resources/*.woff "$app/Contents/Resources/"
  cp "$APP_DIR/Resources/zeus-logo.svg" "$APP_DIR/Resources/AppIcon.icns" "$APP_DIR/Resources/globe.js" "$app/Contents/Resources/"
  cp "$APP_DIR/Resources/dictation-models.json" "$APP_DIR/Resources/ggml-silero-v5.1.2.bin" \
    "$APP_DIR/Resources/THIRD-PARTY-NOTICES.md" "$app/Contents/Resources/"
  cp "$APP_DIR/../install.sh" "$app/Contents/Resources/install.sh"
  codesign --force --sign - --entitlements "$APP_DIR/Resources/Zeus.entitlements" "$app" 2>/dev/null
}

# launch <home>: starts the app of <home> with the debug settings, waits until it runs, lets it run, and stops it.
# It returns 1 when the app does not run.
launch() {
  local home="$1" app="$1/Applications/Zeus.app" waited=0
  if [ "$("$WORK/resolve" "$app")" != "$app" ]; then
    echo "  The app would not see that it is in $home/Applications, so the test does not start it." >&2
    return 1
  fi
  open -g -j -n "$app" \
    --env "HOME=$home" --env "CFFIXED_USER_HOME=$home" \
    --env "ZEUS_APP_TRACE=$home/trace.log" --env "ZEUS_APP_NO_UPDATE=1" \
    --env "ZEUS_EDITOR_STATE_DIR=$home/editor-state" --env "ZEUS_APP_TEST_BACKGROUND=1" \
    --env "ZEUS_APP_NO_MODEL_DOWNLOAD=1"
  until pgrep -f "/$TAG/[^/]*/Applications/Zeus.app/Contents/MacOS/Zeus" >/dev/null; do
    waited=$((waited + 1))
    [ "$waited" -lt 30 ] || return 1
    sleep 1
  done
  sleep "$RUN_SECONDS"
  pgrep -f "/$TAG/[^/]*/Applications/Zeus.app/Contents/MacOS/Zeus" >/dev/null || return 1
  stop_app
}

echo "Release build"
release_home="$WORK/release-home"
mkdir -p "$release_home/Applications"
bundle release "$release_home"
if launch "$release_home"; then pass "the release build runs"; else fail "the release build runs"; fi
if [ ! -e "$release_home/trace.log" ]; then pass "the release build writes no trace file"; else fail "the release build writes no trace file"; fi
if [ ! -e "$release_home/editor-state" ]; then
  pass "the release build makes no editor state folder of ZEUS_EDITOR_STATE_DIR"
else
  fail "the release build makes no editor state folder of ZEUS_EDITOR_STATE_DIR"
fi

echo "Debug build"
debug_home="$WORK/debug-home"
mkdir -p "$debug_home/Applications"
bundle debug "$debug_home"
if launch "$debug_home"; then pass "the debug build runs"; else fail "the debug build runs"; fi
if grep -q "launched: version=9.9.9" "$debug_home/trace.log" 2>/dev/null; then
  pass "the debug build writes the trace file"
else
  fail "the debug build writes the trace file"
fi

if [ "$(user_app_state)" = "$USER_APP_BEFORE" ]; then
  pass "the builds stay in their folders: /Applications/Zeus.app is not changed"
else
  fail "the builds stay in their folders: /Applications/Zeus.app is not changed"
fi

if [ "$FAILURES" -ne 0 ]; then
  echo "$FAILURES check(s) failed"
  exit 1
fi
echo "All checks passed"
