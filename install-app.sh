#!/bin/bash
# Installs the Zeus app on macOS and opens it. The app then sets up everything else.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/theo-henry/zeus-install/main/install-app.sh | bash
#
# The app is in a release of the private zeus repo, so only a GitHub account with access can download it.
# This script runs install.sh with --app-only: it installs the GitHub CLI, logs you in to GitHub, and checks
# your access to all the private Zeus repos first. Without access, it stops and downloads nothing.
# Then it downloads the newest Zeus app release with the GitHub CLI, installs the app, and opens it.
# The app updates itself from the same private releases each time it starts.
#
# The GitHub CLI does not mark its downloads as downloaded from the internet, so the app opens without a
# security prompt although it has no Apple Developer ID signature.
#
# Environment:
#   ZEUS_INSTALL_URL=...   replaces the download address of install.sh (for tests).
#   The test variables of install.sh (ZEUS_APP_REPO, ZEUS_APP_DIR, ZEUS_APP_NO_OPEN, ...) also apply.
set -euo pipefail

WORK=""
ZEUS_INSTALL_URL="${ZEUS_INSTALL_URL:-https://raw.githubusercontent.com/theo-henry/zeus-install/main/install.sh}"

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

  WORK="$(mktemp -d "${TMPDIR:-/tmp}/zeus-app.XXXXXX")"
  trap 'rm -rf "$WORK"' EXIT

  curl -fsSL --retry 3 -o "$WORK/install.sh" "$ZEUS_INSTALL_URL" ||
    fail "The Zeus installer could not be downloaded." "Check your internet connection, then run the same line again."
  # Not from the pipe of "curl | bash": install.sh reads answers from the keyboard itself.
  bash "$WORK/install.sh" --app-only </dev/null
}

# main is called on the last line, so bash has read the full script before it runs.
main "$@"
