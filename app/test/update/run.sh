#!/bin/bash
# Tests of the private Zeus app releases: app/release.sh, install-app.sh (install.sh --app-only), and the
# app's self-update at launch. GitHub is simulated (app/test/sim/payload/gh): no repo, release, or tag is made,
# and nothing is downloaded. Each part uses its own temporary home folder; the real one is not used.
#
# Usage: app/test/update/run.sh [release] [install] [app]     (default: all three parts)
#   release   app/release.sh in a temporary copy of this repo. It builds the app for both architectures (slow).
#   install   install-app.sh on a simulated new Mac: the access check first, then the newest app release.
#   app       the app updates itself, starts its current version without access, and rolls back a failed update.

# check runs its test, in single quotes, with eval; ShellCheck does not see the variables and calls in it.
# shellcheck disable=SC2016,SC2034,SC2119,SC2120
set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$TEST_DIR/../.." && pwd)"
REPO_DIR="$(dirname "$APP_DIR")"
SIM_DIR="$APP_DIR/test/sim"
BUNDLE_ID="io.github.theo-henry.zeus"
PARTS="${*:-release install app}"

# The real path (/private/var, not /var): the app copies that macOS starts run from it, and pgrep sees that path.
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/zeus-update-test.XXXXXX")" && pwd -P)"
# Test actions reach only the app copies that this test starts.
export ZEUS_APP_TEST_ID="update-$$"

FAILURES=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

PREFS_BACKUP="$WORK/prefs.plist"
defaults export "$BUNDLE_ID" "$PREFS_BACKUP" 2>/dev/null || rm -f "$PREFS_BACKUP"
cleanup() {
  pkill -f "$WORK/.*/Zeus.app/Contents/MacOS/Zeus" 2>/dev/null || true
  defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  [ -f "$PREFS_BACKUP" ] && defaults import "$BUNDLE_ID" "$PREFS_BACKUP"
  rm -rf "$WORK"
}
trap cleanup EXIT

wants() { case " $PARTS " in *" $1 "*) return 0 ;; esac; return 1; }

# Simulated releases: releases <state folder> <tag:draft:prerelease>... writes the answer of the releases API.
releases() {
  local state="$1" entry tag draft prerelease first=1
  shift
  mkdir -p "$state"
  {
    printf '['
    for entry in "$@"; do
      IFS=: read -r tag draft prerelease <<<"$entry"
      [ "$first" = 1 ] || printf ','
      first=0
      printf '{"tag_name":"%s","draft":%s,"prerelease":%s,"body":"notes"}' "$tag" "$draft" "$prerelease"
    done
    printf ']\n'
  } >"$state/releases.json"
}

DEV_APP=""
# make_app <version> <folder> [bundle id]: a copy of the development app with another version, signed again.
make_app() {
  rm -rf "$2/Zeus.app"
  mkdir -p "$2"
  ditto "$DEV_APP" "$2/Zeus.app"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $1" "$2/Zeus.app/Contents/Info.plist"
  if [ -n "${3:-}" ]; then /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $3" "$2/Zeus.app/Contents/Info.plist"; fi
  codesign --force --sign - "$2/Zeus.app" 2>/dev/null
}

# publish <state folder> <tag> <version of the app in the zip> [bundle id]: Zeus.zip and its checksum, as release.sh makes them.
publish() {
  local dir="$1/releases/$2" build="$WORK/build-$2-$3"
  make_app "$3" "$build" "${4:-}"
  mkdir -p "$dir"
  ditto -c -k --keepParent "$build/Zeus.app" "$dir/Zeus.zip"
  (cd "$dir" && shasum -a 256 Zeus.zip >Zeus.zip.sha256)
}

app_version() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null; }

if wants install || wants app; then
  echo "Building the development app"
  DEV_APP="$("$APP_DIR/dev-bundle.sh" 2>/dev/null | tail -1)"
fi

# ---------------------------------------------------------------------------------------------------------
if wants release; then
  echo
  echo "Part 1: app/release.sh with a simulated GitHub"
  CLONE="$WORK/release/zeus-install"
  STATE="$WORK/release/state"
  BIN="$WORK/release/bin"
  mkdir -p "$CLONE" "$STATE" "$BIN"
  cp "$SIM_DIR/payload/gh" "$BIN/gh"
  touch "$STATE/gh-login"
  # A copy of this working tree, committed as main and pushed to a local origin.
  (cd "$REPO_DIR" && git ls-files -co --exclude-standard -z | xargs -0 tar -cf -) | tar -xf - -C "$CLONE"
  git -C "$CLONE" init -q -b main
  git -C "$CLONE" add -A
  git -C "$CLONE" -c user.name=test -c user.email=test@example.invalid commit -q -m "test release"
  git init -q --bare "$WORK/release/origin.git"
  git -C "$CLONE" remote add origin "$WORK/release/origin.git"
  git -C "$CLONE" push -q origin main
  releases "$STATE" "v4.0.0:false:false" "app-v1.9.0:false:false" "app-v1.10.0:false:false" "app-v1.11.0:true:false"
  release() { env PATH="$BIN:$PATH" ZEUS_SIM_STATE="$STATE" "$CLONE/app/release.sh" "$@" >"$WORK/release/out" 2>&1; }
  created() { grep -c '^release create' "$STATE/gh.log" 2>/dev/null || true; }

  touch "$CLONE/untracked-file"
  check "a working tree with changes is refused" '! release && grep -q "working tree has changes" "$WORK/release/out" && [ "$(created)" = 0 ]'
  rm "$CLONE/untracked-file"
  git -C "$CLONE" -c user.name=test -c user.email=test@example.invalid commit -q --allow-empty -m "not pushed"
  check "a commit that is not the newest main commit is refused" '! release && grep -q "not the newest commit of main" "$WORK/release/out" && [ "$(created)" = 0 ]'
  git -C "$CLONE" reset -q --hard origin/main
  check "a version that is not X.Y.Z is refused" '! release 1.2 && grep -q "must be X.Y.Z" "$WORK/release/out"'
  check "a version that is not higher than the newest app release is refused" '! release 1.9.5 && grep -q "not higher" "$WORK/release/out"'
  check "an existing release is refused (also a draft)" '! release 1.11.0 && grep -q "already exists" "$WORK/release/out"'
  check "nothing was released for the refused runs" '[ "$(created)" = 0 ]'

  echo "  (building the release app; this takes some minutes)"
  if release; then pass "release.sh builds and publishes"; else fail "release.sh builds and publishes"; sed 's/^/    /' "$WORK/release/out"; fi
  # app-v1.11.0 is a draft but its tag exists; the next free version after the newest one is 1.11.1.
  TAG="app-v1.11.1"
  check "the version is the newest app release plus 1 in the last number ($TAG)" 'grep -q "^release create $TAG " "$STATE/gh.log"'
  check "the release goes to the private zeus repo and is not marked as its latest release" \
    'grep "^release create" "$STATE/gh.log" | grep -q -- "-R theo-henry/zeus --title Zeus app 1.11.1 --latest=false"'
  check "the release has Zeus.zip and its SHA-256 checksum" \
    '(cd "$STATE/created/$TAG" && shasum -a 256 -c Zeus.zip.sha256 >/dev/null)'
  ditto -x -k "$STATE/created/$TAG/Zeus.zip" "$WORK/release/unpacked" 2>/dev/null || true
  check "the released app has the version, the bundle identifier, and a valid signature" \
    '[ "$(app_version "$WORK/release/unpacked/Zeus.app")" = 1.11.1 ] && codesign --verify --strict "$WORK/release/unpacked/Zeus.app" &&
     [ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$WORK/release/unpacked/Zeus.app/Contents/Info.plist")" = "$BUNDLE_ID" ]'
  check "the released app is for Apple silicon and Intel" \
    'lipo -archs "$WORK/release/unpacked/Zeus.app/Contents/MacOS/Zeus" | grep -q arm64 && lipo -archs "$WORK/release/unpacked/Zeus.app/Contents/MacOS/Zeus" | grep -q x86_64'
fi

# ---------------------------------------------------------------------------------------------------------
if wants install; then
  echo
  echo "Part 2: install-app.sh on a simulated new Mac"
  # new_mac <name>: Git and the GitHub login are there; Anaconda and the GitHub CLI install (simulated).
  new_mac() {
    SANDBOX="$WORK/$1/home"
    STATE="$WORK/$1/state"
    APPS="$WORK/$1/Applications"
    OUT="$WORK/$1/out"
    mkdir -p "$SANDBOX" "$STATE/clt-dir/usr/bin" "$APPS"
    ln -sf /usr/bin/git "$STATE/clt-dir/usr/bin/git"
    touch "$STATE/clt" "$STATE/gh-login"
  }
  install_app() {
    env HOME="$SANDBOX" PATH="$SIM_DIR/stubs:/usr/bin:/bin:/usr/sbin:/sbin" \
      ZEUS_SIM_STATE="$STATE" ZEUS_SIM_PAYLOAD="$SIM_DIR/payload" ZEUS_SIM_INSTALLER="$REPO_DIR/install.sh" \
      ZEUS_INSTALL_SYSTEM_CONDA_DIRS="" ZEUS_INSTALL_ACCEPT_ANACONDA_LICENSE=yes \
      ZEUS_INSTALL_URL="file://$REPO_DIR/install.sh" ZEUS_APP_DIR="$APPS" ZEUS_APP_NO_OPEN=1 "$@" \
      bash "$REPO_DIR/install-app.sh" >"$OUT" 2>&1
  }
  downloads() { grep -c 'releases\|release download' "$STATE/gh.log" 2>/dev/null || true; }
  ALL_RELEASES=("v5.0.0:false:false" "app-v1.0.0:false:false" "app-v1.9.0:false:false" "app-v1.10.0:false:false"
    "app-v1.11.0:false:true" "app-v1.12.0:true:false" "app-v2.0.0-beta:false:false")

  new_mac install-noaccess
  releases "$STATE" "${ALL_RELEASES[@]}"
  publish "$STATE" app-v1.10.0 1.10.0
  check "without access to one private repo, install-app.sh stops" '! install_app ZEUS_SIM_NO_ACCESS=theo-henry/celonis-pql'
  check "it names the missing repo" 'grep -q "has no access to all the private Zeus repos" "$OUT" && grep -q "theo-henry/celonis-pql" "$OUT"'
  check "it does not look for or download the app" '[ "$(downloads)" = 0 ] && [ ! -e "$APPS/Zeus.app" ]'

  new_mac install-ok
  releases "$STATE" "${ALL_RELEASES[@]}"
  publish "$STATE" app-v1.10.0 1.10.0
  check "with access, install-app.sh installs the Zeus app" 'install_app'
  check "it runs the GitHub login and the access check first" \
    'grep -n "4/6 GitHub login\|5/6 Access to the Zeus repos\|6/6 Zeus app" "$OUT" | cut -d: -f2- | tr "\n" "|" | grep -q "4/6.*5/6.*6/6"'
  check "it downloads the newest app release from the private zeus repo (not drafts, pre-releases, or other tags)" \
    'grep -q "^release download app-v1.10.0 -R theo-henry/zeus" "$STATE/gh.log"'
  check "the installed app is version 1.10.0 with a valid signature" \
    '[ "$(app_version "$APPS/Zeus.app")" = 1.10.0 ] && codesign --verify --strict "$APPS/Zeus.app"'
  check "it tells the user that the app opens and updates itself" 'grep -q "The Zeus app is installed." "$OUT" && grep -q "updates itself" "$OUT"'
  check "it installs nothing after step 5 that the app does in its setup window" '[ ! -d "$SANDBOX/.local/node" ] && [ ! -d "$SANDBOX/Code/zeus" ]'

  new_mac install-badsum
  releases "$STATE" "app-v1.10.0:false:false"
  publish "$STATE" app-v1.10.0 1.10.0
  echo "0000  Zeus.zip" >"$STATE/releases/app-v1.10.0/Zeus.zip.sha256"
  check "a download with a wrong checksum stops the install" '! install_app && grep -q "checksum mismatch" "$OUT" && [ ! -e "$APPS/Zeus.app" ]'

  new_mac install-badversion
  releases "$STATE" "app-v1.10.0:false:false"
  publish "$STATE" app-v1.10.0 1.9.0
  check "a download with another version than its tag stops the install" '! install_app && grep -q "is not Zeus 1.10.0" "$OUT" && [ ! -e "$APPS/Zeus.app" ]'

  new_mac install-norelease
  releases "$STATE" "v5.0.0:false:false"
  check "without an app release, the install stops with a clear message" '! install_app && grep -q "No Zeus app release was found" "$OUT"'
fi

# ---------------------------------------------------------------------------------------------------------
if wants app; then
  echo
  echo "Part 3: the app updates itself at launch"
  BIN="$WORK/bin"
  mkdir -p "$BIN"
  cat >"$WORK/act.swift" <<'SWIFT'
import Foundation
let testID = ProcessInfo.processInfo.environment["ZEUS_APP_TEST_ID"].map { "." + $0 } ?? ""
DistributedNotificationCenter.default().postNotificationName(Notification.Name("io.github.theo-henry.zeus.test" + testID),
    object: CommandLine.arguments[1], userInfo: nil, deliverImmediately: true)
SWIFT
  swiftc -O -o "$BIN/act" "$WORK/act.swift" 2>/dev/null

  # app_case <name> <installed version>: the app in a simulated Applications folder, with a simulated GitHub CLI.
  app_case() {
    NAME="$1"
    SANDBOX="$WORK/$1/home"
    STATE="$WORK/$1/state"
    APPS="$WORK/$1/Applications"
    TRACE="$WORK/$1/trace.log"
    SUPPORT="$SANDBOX/Library/Application Support/Zeus"
    mkdir -p "$SANDBOX/.local/bin" "$STATE" "$SUPPORT"
    printf 'export PATH="%s:/usr/bin:/bin:/usr/sbin:/sbin"\n' "$SIM_DIR/stubs" >"$SANDBOX/.zprofile"
    cp "$SIM_DIR/payload/gh" "$SANDBOX/.local/bin/gh"
    touch "$STATE/gh-login"
    echo "user state" >"$SUPPORT/user-state"
    make_app "$2" "$APPS"
    defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
    defaults write "$BUNDLE_ID" showMenuBar -bool false
  }
  launch() {
    env HOME="$SANDBOX" ZEUS_APP_TRACE="$TRACE" ZEUS_SIM_STATE="$STATE" ZEUS_SIM_PAYLOAD="$SIM_DIR/payload" \
      ZEUS_SIM_INSTALLER="$REPO_DIR/install.sh" ZEUS_INSTALL_SYSTEM_CONDA_DIRS="" "$@" \
      "$APPS/Zeus.app/Contents/MacOS/Zeus" >"$WORK/$NAME/app.out" 2>&1 &
    APP_PID=$!
  }
  wait_for() {
    local pattern="$1" limit="${2:-60}" waited=0
    until grep -q -- "$pattern" "$TRACE" 2>/dev/null; do
      sleep 0.5
      waited=$((waited + 1))
      if [ "$waited" -ge $((limit * 2)) ]; then echo "    (timed out waiting for: $pattern)"; return 1; fi
    done
  }
  copies() { pgrep -f "$APPS/Zeus.app/Contents/MacOS/Zeus" | wc -l | tr -d ' '; }
  # Quits every copy of this case's app.
  quit_all() {
    "$BIN/act" quit
    local waited=0
    while [ "$(copies)" != 0 ] && [ "$waited" -lt 120 ]; do sleep 0.5; waited=$((waited + 1)); done
    if [ "$(copies)" = 0 ]; then pass "the app quits"; else fail "the app quits"; pkill -f "$APPS/Zeus.app/Contents/MacOS/Zeus" || true; fi
    cp "$TRACE" "$WORK/$NAME.trace" 2>/dev/null || true
  }
  work_folder() { sed -n 's/.*update: downloading [^ ]* to //p' "$TRACE" | head -1; }

  app_case update 1.0.0
  releases "$STATE" "v5.0.0:false:false" "app-v1.0.0:false:false" "app-v1.1.0:false:false" "app-v1.2.0:true:false"
  publish "$STATE" app-v1.1.0 1.1.0
  launch
  check "the app finds the newer release at launch" 'wait_for "update: current=1.0.0 newest=1.1.0" 60'
  check "it shows the loading screen during the check" 'wait_for "update window: checking" 60'
  check "the loading screen shows the download" 'wait_for "update window: downloading 1.1.0" 120'
  check "the new copy starts and confirms the update" 'wait_for "update: confirmed 1.0.0 -> 1.1.0" 120'
  check "the old copy finishes the update and quits" 'wait_for "update: done 1.0.0 -> 1.1.0" 120 && sleep 1 && ! kill -0 "$APP_PID" 2>/dev/null'
  check "the app in Applications is now version 1.1.0 with a valid signature" \
    '[ "$(app_version "$APPS/Zeus.app")" = 1.1.0 ] && codesign --verify --strict "$APPS/Zeus.app"'
  check "the new copy runs version 1.1.0 and opens the setup window" 'grep -q "launched: version=1.1.0" "$TRACE" && wait_for "setup ended: check=true" 60'
  check "the new copy does not check again" '[ "$(grep -c "update: current=" "$TRACE")" = 1 ]'
  check "the old copy and the update files are removed" \
    '[ -n "$(work_folder)" ] && [ ! -e "$(work_folder)" ] && [ ! -e "$SUPPORT/update.json" ]'
  check "the user state is unchanged" \
    '[ "$(cat "$SUPPORT/user-state")" = "user state" ] && [ "$(defaults read "$BUNDLE_ID" showMenuBar)" = 0 ]'
  check "one copy of the app runs" '[ "$(copies)" = 1 ]'
  quit_all

  app_case current 1.1.0
  releases "$STATE" "app-v1.0.0:false:false" "app-v1.1.0:false:false"
  launch
  check "an app that is up to date starts at once" 'wait_for "update: none (up to date)" 60 && wait_for "setup ended: check=true" 60'
  check "it downloads nothing" '! grep -q "release download" "$STATE/gh.log" && ! grep -q "update window: downloading" "$TRACE"'
  quit_all

  app_case noaccess 1.0.0
  releases "$STATE" "app-v1.1.0:false:false"
  publish "$STATE" app-v1.1.0 1.1.0
  launch ZEUS_SIM_NO_ACCESS=theo-henry/zeus
  check "without access (or offline), the app starts its current version" \
    'wait_for "update: none (no release list" 60 && wait_for "setup ended: check=true" 60 && [ "$(app_version "$APPS/Zeus.app")" = 1.0.0 ]'
  check "it shows no download and no message" '! grep -q "update window: downloading" "$TRACE" && ! grep -qi "alert\|failed" "$TRACE"'
  quit_all

  app_case badsum 1.0.0
  releases "$STATE" "app-v1.1.0:false:false"
  publish "$STATE" app-v1.1.0 1.1.0
  echo "0000  Zeus.zip" >"$STATE/releases/app-v1.1.0/Zeus.zip.sha256"
  launch
  check "a download with a wrong checksum is not installed" \
    'wait_for "update: none (failed: checksum mismatch)" 60 && [ "$(app_version "$APPS/Zeus.app")" = 1.0.0 ]'
  check "the app then starts its current version" 'wait_for "setup ended: check=true" 60'
  check "the update files are removed" '[ -n "$(work_folder)" ] && [ ! -e "$(work_folder)" ]'
  quit_all

  app_case badid 1.0.0
  releases "$STATE" "app-v1.1.0:false:false"
  publish "$STATE" app-v1.1.0 1.1.0 com.example.other
  launch
  check "a download with another bundle identifier is not installed" \
    'wait_for "update: none (failed: not Zeus 1.1.0)" 60 && [ "$(app_version "$APPS/Zeus.app")" = 1.0.0 ]'
  quit_all

  app_case rollback 1.0.0
  releases "$STATE" "app-v1.1.0:false:false"
  publish "$STATE" app-v1.1.0 1.1.0
  launch ZEUS_APP_TEST_NO_CONFIRM=1
  check "when the new copy does not confirm, the old copy is put back" 'wait_for "update: rolled back to 1.0.0" 120'
  check "the app in Applications is version 1.0.0 again" \
    '[ "$(app_version "$APPS/Zeus.app")" = 1.0.0 ] && codesign --verify --strict "$APPS/Zeus.app"'
  check "the old copy continues and opens the setup window" 'wait_for "setup ended: check=true" 60 && kill -0 "$APP_PID" 2>/dev/null'
  check "the new copy was stopped and the update files are removed" \
    'sleep 1 && [ "$(copies)" = 1 ] && [ ! -e "$(work_folder)" ] && [ ! -e "$SUPPORT/update.json" ]'
  quit_all
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  printf '\033[32mAll checks passed.\033[0m\n'
else
  printf '\033[31m%s checks failed.\033[0m\n' "$FAILURES"
  exit 1
fi
