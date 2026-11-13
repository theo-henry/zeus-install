#!/bin/bash
# Publishes a Zeus app release. The installer and the app's self-update download the newest one.
# For the maintainer only. Run it on a Mac after each merged app change.
#
# Usage: app/release.sh [version]
#   version   X.Y.Z, higher than the newest app release. Default: the newest app release with the
#             last number plus 1, or 0.1.0 for the first release.
#
# It builds the app (app/build.sh) from the newest main commit, checks the zip, and makes the release
# "app-v<version>" with the assets Zeus.zip and Zeus.zip.sha256 in the private zeus repo.
# The release is not marked as the latest release of that repo, so the repo's other releases do not change.
# The repo is private: only GitHub accounts with access can download the app.
# Needs the Xcode Command Line Tools, and gh logged in with write access to the repo. No token is stored.
#
# Environment:
#   ZEUS_RELEASE_REPO="owner/name"   replaces the repo of the release (for tests).
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$APP_DIR")"
RELEASE_REPO="${ZEUS_RELEASE_REPO:-theo-henry/zeus}"
BUNDLE_ID="io.github.theo-henry.zeus"
TAG_PREFIX="app-v"
WORK=""

fail() {
  printf '\033[1;31mStopped:\033[0m %s\n' "$1" >&2
  shift
  local line
  for line in "$@"; do printf '    %s\n' "$line" >&2; done
  exit 1
}

# Returns success when version $1 is higher than version $2 (X.Y.Z).
version_higher() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]
}

# Checks that the checkout is clean and is the newest commit of main, so that each release has known code.
check_checkout() {
  [ -z "$(git -C "$REPO_DIR" status --porcelain)" ] ||
    fail "The working tree has changes." "Commit or remove them, then run release.sh again."
  git -C "$REPO_DIR" fetch --quiet origin main ||
    fail "git cannot fetch main from origin."
  local head main
  head="$(git -C "$REPO_DIR" rev-parse HEAD)"
  main="$(git -C "$REPO_DIR" rev-parse origin/main)"
  [ "$head" = "$main" ] ||
    fail "This checkout is not the newest commit of main." \
      "HEAD is $head, origin/main is $main." "Run: git switch main && git pull --ff-only"
}

# Checks Zeus.app in the zip: the bundle identifier, the version, and the signature.
check_zip() {
  local zip="$1" version="$2" plist
  ditto -x -k "$zip" "$WORK/check" || fail "The built Zeus.zip cannot be unpacked."
  plist="$WORK/check/Zeus.app/Contents/Info.plist"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null)" = "$BUNDLE_ID" ] ||
    fail "The built app does not have the bundle identifier $BUNDLE_ID."
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null)" = "$version" ] ||
    fail "The built app does not have the version $version."
  codesign --verify --strict "$WORK/check/Zeus.app" || fail "The signature of the built app is not valid."
}

main() {
  command -v gh >/dev/null 2>&1 || fail "The GitHub CLI (gh) is not installed."
  gh auth status -h github.com >/dev/null 2>&1 || fail "gh is not logged in to GitHub." "Run: gh auth login"
  check_checkout

  local tags newest version="${1:-}"
  tags="$(gh api "repos/$RELEASE_REPO/releases?per_page=100" --jq '.[].tag_name')" ||
    fail "gh cannot read the releases of $RELEASE_REPO."
  newest="$(printf '%s\n' "$tags" | grep -E "^${TAG_PREFIX}[0-9]+\.[0-9]+\.[0-9]+\$" | sed "s/^$TAG_PREFIX//" | sort -V | tail -1 || true)"
  if [ -z "$version" ]; then
    if [ -n "$newest" ]; then
      version="${newest%.*}.$((${newest##*.} + 1))"
    else
      version="0.1.0"
    fi
  fi
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "The version must be X.Y.Z, for example 1.2.3 (got '$version')."
  if printf '%s\n' "$tags" | grep -qxF "$TAG_PREFIX$version"; then
    fail "The release $TAG_PREFIX$version already exists in $RELEASE_REPO."
  fi
  if [ -n "$newest" ] && ! version_higher "$version" "$newest"; then
    fail "The version $version is not higher than the newest app release ($newest)."
  fi

  WORK="$(mktemp -d "${TMPDIR:-/tmp}/zeus-release.XXXXXX")"
  trap 'rm -rf "$WORK"' EXIT

  printf 'Building the Zeus app %s\n' "$version"
  "$APP_DIR/build.sh" "$version" >/dev/null
  local out="$APP_DIR/build" commit
  check_zip "$out/Zeus.zip" "$version"
  (cd "$out" && shasum -a 256 Zeus.zip >Zeus.zip.sha256)

  commit="$(git -C "$REPO_DIR" rev-parse HEAD)"
  printf 'Publishing %s%s in %s\n' "$TAG_PREFIX" "$version" "$RELEASE_REPO"
  gh release create "$TAG_PREFIX$version" "$out/Zeus.zip" "$out/Zeus.zip.sha256" -R "$RELEASE_REPO" \
    --title "Zeus app $version" --latest=false \
    --notes "The Zeus app $version, built from theo-henry/zeus-install commit $commit.
The installer and the app's self-update use the newest $TAG_PREFIX release." ||
    fail "gh could not make the release." "If a part of it was made, delete it on GitHub before you try again."
  printf 'Released the Zeus app %s.\n' "$version"
}

main "$@"
