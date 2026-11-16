#!/bin/bash
# Checks that the globe of the app is the same as the globe of the Zeus chat page (private repo theo-henry/zeus-editor, main).
# The loading screen of the app shows its own copy of the globe and hands over to the chat globe, so both must look the same:
#   - app/Resources/globe.js must equal src/chat/client/globe.js of zeus-editor, apart from the header comment and `export`.
#   - The background colour of the loading screen (Loader.swift, the page and LoaderPage.background) and of the status page (StatusPage.swift) must equal
#     --ink-900 in src/chat/chat.css of zeus-editor.
# release.sh runs this check. It is not part of CI: the CI token cannot read the private zeus-editor repo.
# Needs gh logged in with read access to zeus-editor. Exit 0: same. Exit 1: different, or zeus-editor cannot be read.
#
# Environment:
#   ZEUS_EDITOR_REPO="owner/name"   replaces the zeus-editor repo (for tests).
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
EDITOR_REPO="${ZEUS_EDITOR_REPO:-theo-henry/zeus-editor}"
GLOBE_PATH="src/chat/client/globe.js"
CSS_PATH="src/chat/chat.css"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/zeus-globe-check.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() {
  printf '\033[1;31mStopped:\033[0m %s\n' "$1" >&2
  shift
  local line
  for line in "$@"; do printf '    %s\n' "$line" >&2; done
  exit 1
}

# fetch <path in zeus-editor> <output file>: the file on main, as text.
fetch() {
  gh api -H "Accept: application/vnd.github.raw" "repos/$EDITOR_REPO/contents/$1?ref=main" >"$2" 2>/dev/null ||
    fail "gh cannot read $1 from $EDITOR_REPO (main)." \
      "The check needs gh logged in with read access to $EDITOR_REPO." \
      "To release without this check, set ZEUS_SKIP_GLOBE_CHECK=1."
  [ -s "$2" ] || fail "$1 from $EDITOR_REPO is empty."
}

# body <in> <out>: the file without its leading comment lines and without "export " at the start of a line.
body() {
  awk 'body || !/^\/\// { body = 1; sub(/^export[ \t]+/, ""); print }' "$1" >"$2"
}

# hex <text>: the first #rrggbb colour, in lower case.
hex() { grep -oE '#[0-9a-fA-F]{6}' | head -1 | tr 'A-F' 'a-f'; }

fetch "$GLOBE_PATH" "$WORK/editor-globe.js"
fetch "$CSS_PATH" "$WORK/chat.css"
body "$WORK/editor-globe.js" "$WORK/editor.body"
body "$APP_DIR/Resources/globe.js" "$WORK/app.body"
if ! diff -u "$WORK/editor.body" "$WORK/app.body" >"$WORK/globe.diff"; then
  head -n 40 "$WORK/globe.diff" | sed 's/^/    /' >&2
  fail "app/Resources/globe.js is not the same as $GLOBE_PATH of $EDITOR_REPO." \
    "The loading screen and the chat page must show the same globe." \
    "Copy the zeus-editor file to app/Resources/globe.js (keep the header comment, and remove the word export), then run again."
fi

ink="$(grep -E '^[[:space:]]*--ink-900:' "$WORK/chat.css" | hex || true)"
[ -n "$ink" ] || fail "$CSS_PATH of $EDITOR_REPO has no --ink-900 colour."
loader="$(grep -E '#bg[[:space:]]*\{' "$APP_DIR/Sources/Zeus/Loader.swift" | grep -oE 'background:[[:space:]]*#[0-9a-fA-F]{6}' | hex || true)"
status="$(grep -oE -e '--bg:[[:space:]]*#[0-9a-fA-F]{6}' "$APP_DIR/Sources/Zeus/StatusPage.swift" | hex || true)"
swift="$(grep -E 'static let background = NSColor' "$APP_DIR/Sources/Zeus/Loader.swift" | grep -oE '0x[0-9A-Fa-f]{2}' | sed 's/^0x//' | tr -d '\n' | tr 'A-F' 'a-f' || true)"
[ -n "$swift" ] && swift="#$swift"
[ -n "$loader" ] || fail "app/Sources/Zeus/Loader.swift has no #bg background colour that this check can read."
[ -n "$status" ] || fail "app/Sources/Zeus/StatusPage.swift has no --bg colour that this check can read."
[ "$loader" = "$ink" ] ||
  fail "The loading screen background in Loader.swift ($loader) is not --ink-900 of $EDITOR_REPO ($ink)." \
    "Change the background in app/Sources/Zeus/Loader.swift."
[ "$swift" = "$ink" ] ||
  fail "LoaderPage.background in Loader.swift (${swift:-not found}) is not --ink-900 of $EDITOR_REPO ($ink)." \
    "Change the colour in app/Sources/Zeus/Loader.swift."
[ "$status" = "$ink" ] ||
  fail "The status page background in StatusPage.swift ($status) is not --ink-900 of $EDITOR_REPO ($ink)." \
    "Change --bg in app/Sources/Zeus/StatusPage.swift."
printf 'The globe and the background colour are the same as in %s.\n' "$EDITOR_REPO"
