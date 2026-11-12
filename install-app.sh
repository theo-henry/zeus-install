#!/bin/bash
# Installs the Zeus app on macOS and opens it. The app then sets up everything else.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/theo-henry/zeus-install/main/install-app.sh | bash
#
# The app is downloaded with curl, so macOS does not mark it as downloaded from the internet, and it
# opens without a security prompt although it has no Apple Developer ID signature.
#
# Environment:
#   ZEUS_APP_URL=...       replaces the download address of Zeus.zip (for tests).
#   ZEUS_APP_NO_OPEN=1     installs the app but does not open it (for tests).
#   ZEUS_APP_DIR=...       installs into this folder instead of /Applications (for tests).
set -euo pipefail

WORK=""
ZEUS_APP_URL="${ZEUS_APP_URL:-https://github.com/theo-henry/zeus-install/releases/latest/download/Zeus.zip}"

fail() {
  printf '\n\033[1;31mStopped:\033[0m %s\n' "$1" >&2
  shift
  local line
  for line in "$@"; do printf '    %s\n' "$line" >&2; done
  exit 1
}

main() {
  [ "$(uname -s)" = "Darwin" ] || fail "The Zeus app works only on macOS."
  [ "$(id -u)" -ne 0 ] || fail "Do not run this with sudo." "Run the install line without sudo."

  # /Applications needs an administrator account; ~/Applications works for every account.
  local target="${ZEUS_APP_DIR:-/Applications}"
  if [ ! -w "$target" ]; then
    target="$HOME/Applications"
    mkdir -p "$target"
  fi

  WORK="$(mktemp -d "${TMPDIR:-/tmp}/zeus-app.XXXXXX")"
  trap 'rm -rf "$WORK"' EXIT
  local work="$WORK"

  printf '\033[1m%s\033[0m\n' "Installing the Zeus app"
  curl -fL --progress-bar --retry 3 -o "$work/Zeus.zip" "$ZEUS_APP_URL" ||
    fail "The download of the Zeus app failed." "Check your internet connection, then run the same line again."
  ditto -x -k "$work/Zeus.zip" "$work/unpacked" ||
    fail "The Zeus app download is damaged." "Run the same line again."
  [ -d "$work/unpacked/Zeus.app" ] || fail "The download does not contain Zeus.app."
  codesign --verify --strict "$work/unpacked/Zeus.app" 2>/dev/null ||
    fail "The Zeus app in the download is damaged or changed (signature check failed)."

  # Quit a running copy, so that it can be replaced. Its sessions stop as when you quit it yourself.
  if pgrep -f "$target/Zeus.app/Contents/MacOS/Zeus" >/dev/null 2>&1; then
    osascript -e 'tell application id "io.github.theo-henry.zeus" to quit' >/dev/null 2>&1 || true
    local waited=0
    while pgrep -f "$target/Zeus.app/Contents/MacOS/Zeus" >/dev/null 2>&1 && [ "$waited" -lt 30 ]; do
      sleep 1
      waited=$((waited + 1))
    done
  fi
  rm -rf "$target/Zeus.app"
  ditto "$work/unpacked/Zeus.app" "$target/Zeus.app"
  xattr -dr com.apple.quarantine "$target/Zeus.app" 2>/dev/null || true
  printf '    Installed %s/Zeus.app\n' "$target"

  if [ "${ZEUS_APP_NO_OPEN:-}" != "1" ]; then
    open "$target/Zeus.app"
    printf '    The Zeus app is open. Follow the setup in its window.\n'
  fi
}

# main is called on the last line, so bash has read the full script before it runs.
main "$@"
