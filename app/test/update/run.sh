#!/bin/bash
# Tests of the private Zeus app releases: app/release.sh, install-app.sh (install.sh --app-only), the
# app's self-update at launch, and the app update from the settings of a Zeus page. GitHub is simulated
# (app/test/sim/payload/gh): no repo, release, or tag is made, and nothing is downloaded. Each part uses its own
# temporary home folder; the real one is not used.
#
# Usage: app/test/update/run.sh [release] [install] [app] [upgrade] [settings]     (default: all five parts)
#   release   app/release.sh in a temporary copy of this repo. It builds the app for both architectures (slow).
#   install   install-app.sh on a simulated new Mac: the access check first, then the newest app release.
#   app       the app updates itself, starts its current version without access, and rolls back a failed update.
#   upgrade   install-app.sh on a Mac with an older app and user data: it updates the app (also an open app),
#             keeps every user data file, opens an app that is up to date, and puts the old app back when the
#             new app does not start.
#   settings  "Check for updates" and "Update now" of a chat page: the app updates while tabs are open and opens
#             the same tabs again (sessions resumed, project, name, unsent text), also after a roll back.
#
# Time limits: each app case stops all its app copies after ZEUS_UPDATE_TEST_CASE_LIMIT seconds (default 300) and fails,
# and the whole test stops after ZEUS_UPDATE_TEST_LIMIT seconds (default 3600). ZEUS_UPDATE_TEST_TRACES=<folder>
# keeps the trace and the session records of each app case there.
# ZEUS_UPDATE_TEST_CASES="<case>..." runs only those cases of the settings part (settings, settings-current,
# settings-noaccess, settings-starting, settings-rollback).

# check runs its test, in single quotes, with eval; ShellCheck does not see the variables and calls in it.
# shellcheck disable=SC2016,SC2034,SC2119,SC2120
set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$TEST_DIR/../.." && pwd)"
REPO_DIR="$(dirname "$APP_DIR")"
SIM_DIR="$APP_DIR/test/sim"
BUNDLE_ID="io.github.theo-henry.zeus"
PARTS="${*:-release install app upgrade settings}"

# The real path (/private/var, not /var): the app copies that macOS starts run from it, and pgrep sees that path.
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/zeus-update-test.XXXXXX")" && pwd -P)"
# Test actions reach only the app copies that this test starts.
export ZEUS_APP_TEST_ID="update-$$"
# The app copies of this run keep their settings in a domain of their own, not in the settings of the user.
export ZEUS_APP_DEFAULTS_SUITE="io.github.theo-henry.zeus.test-$ZEUS_APP_TEST_ID"
PREFS_DOMAIN="$ZEUS_APP_DEFAULTS_SUITE"
# The app stays behind the windows of other apps and does not take the keyboard (debug builds).
export ZEUS_APP_TEST_BACKGROUND=1

FAILURES=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
# A failed check shows the end of the app's trace, so that a CI log tells what the app did.
fail() {
  printf '  \033[31mFAIL\033[0m %s\n' "$1"
  FAILURES=$((FAILURES + 1))
  if [ -n "${TRACE:-}" ] && [ -f "$TRACE" ]; then tail -n 25 "$TRACE" | sed 's/^/    | /'; fi
}
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

CASE_LIMIT="${ZEUS_UPDATE_TEST_CASE_LIMIT:-300}"
TOTAL_LIMIT="${ZEUS_UPDATE_TEST_LIMIT:-3600}"
TRACES="${ZEUS_UPDATE_TEST_TRACES:-}"
[ -n "$TRACES" ] && mkdir -p "$TRACES"
CASE_WATCHDOG=""
# stop_watchdog <pid>: stops a time limit and its sleep. A left sleep keeps the output of the test open, so a pipe
# after the test (run.sh | tee) would wait until the sleep ends.
# The time limit stops first, so that it does not go on to its action when its sleep ends.
stop_watchdog() {
  [ -n "$1" ] || return 0
  local sleeps
  sleeps="$(pgrep -P "$1" 2>/dev/null || true)"
  kill "$1" 2>/dev/null || true
  # shellcheck disable=SC2086
  [ -z "$sleeps" ] || kill $sleeps 2>/dev/null || true
}
# stop_copies <folder pattern>: stops the app copies there, also an app copy that does not quit.
stop_copies() {
  pkill -f "$1/Zeus.app/Contents/MacOS/Zeus" 2>/dev/null || true
  sleep 1
  pkill -9 -f "$1/Zeus.app/Contents/MacOS/Zeus" 2>/dev/null || true
}
cleanup() {
  stop_watchdog "$CASE_WATCHDOG"
  stop_watchdog "${TOTAL_WATCHDOG:-}"
  stop_copies "$WORK/.*"
  defaults delete "$PREFS_DOMAIN" >/dev/null 2>&1 || true
  # defaults delete can leave the empty settings file of the domain.
  rm -f "$HOME/Library/Preferences/$PREFS_DOMAIN.plist"
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 1' INT TERM
# The whole test never runs longer than TOTAL_LIMIT.
( sleep "$TOTAL_LIMIT" >/dev/null 2>&1; echo "  (the test took longer than ${TOTAL_LIMIT}s and stops)" >&2; kill -TERM $$ ) &
TOTAL_WATCHDOG=$!

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

if wants install || wants app || wants upgrade || wants settings; then
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
if wants app || wants upgrade || wants settings; then
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
    # Each case stops all its app copies after CASE_LIMIT seconds; quit_all then reports the case as failed.
    stop_watchdog "$CASE_WATCHDOG"
    ( sleep "$CASE_LIMIT" >/dev/null 2>&1; touch "$WORK/$1/timed-out"; stop_copies "$APPS" ) &
    CASE_WATCHDOG=$!
    printf 'export PATH="%s:/usr/bin:/bin:/usr/sbin:/sbin"\n' "$SIM_DIR/stubs" >"$SANDBOX/.zprofile"
    cp "$SIM_DIR/payload/gh" "$SANDBOX/.local/bin/gh"
    touch "$STATE/gh-login"
    echo "user state" >"$SUPPORT/user-state"
    make_app "$2" "$APPS"
    defaults delete "$PREFS_DOMAIN" >/dev/null 2>&1 || true
    defaults write "$PREFS_DOMAIN" showMenuBar -bool false
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
    if [ "$(copies)" = 0 ]; then pass "the app quits"; else fail "the app quits"; stop_copies "$APPS"; fi
    if [ -e "$WORK/$NAME/timed-out" ]; then fail "the case $NAME ends within ${CASE_LIMIT}s"; fi
    stop_watchdog "$CASE_WATCHDOG"
    CASE_WATCHDOG=""
    if [ -n "$TRACES" ]; then
      cp "$TRACE" "$TRACES/$NAME.trace" 2>/dev/null || true
      cp "$STATE/sessions" "$TRACES/$NAME.sessions" 2>/dev/null || true
    fi
  }
  work_folder() { sed -n 's/.*update: downloading [^ ]* to //p' "$TRACE" | head -1; }
  # The old copy stops the new copy and removes the update files; under load this takes some time.
  # After a roll back, update.json only marks the roll back while the old copy runs (Pending.rolledBack).
  rollback_cleaned() {
    [ "$(copies)" = 1 ] && [ ! -e "$(work_folder)" ] &&
      { [ ! -e "$SUPPORT/update.json" ] || grep -q '"rolledBack":true' "$SUPPORT/update.json"; }
  }
  # A late start of the new copy after the roll back (macOS can start it late under load): it quits at once and
  # does not update again.
  late_copy_quits() {
    local before late_pid waited=0
    before="$(grep -c "update: current=" "$TRACE" || true)"
    env HOME="$SANDBOX" ZEUS_APP_TRACE="$TRACE" ZEUS_SIM_STATE="$STATE" ZEUS_SIM_PAYLOAD="$SIM_DIR/payload" \
      ZEUS_APP_TEST_NO_CONFIRM=1 "$APPS/Zeus.app/Contents/MacOS/Zeus" >"$WORK/$NAME/late.out" 2>&1 &
    late_pid=$!
    while kill -0 "$late_pid" 2>/dev/null && [ "$waited" -lt 40 ]; do sleep 0.5; waited=$((waited + 1)); done
    if kill -0 "$late_pid" 2>/dev/null; then kill -9 "$late_pid"; return 1; fi
    grep -q "update: a late copy of the rolled back update to 1.1.0 quits" "$TRACE" &&
      [ "$(grep -c "update: current=" "$TRACE" || true)" = "$before" ] && [ "$(copies)" = 1 ]
  }
  # wait_until <command> [seconds]: waits until the command succeeds.
  wait_until() {
    local waited=0 limit="${2:-60}"
    until "$1"; do
      sleep 0.5
      waited=$((waited + 1))
      if [ "$waited" -ge $((limit * 2)) ]; then echo "    (timed out waiting for: $1)"; return 1; fi
    done
  }
fi

if wants app; then
  echo
  echo "Part 3: the app updates itself at launch"

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
    '[ "$(cat "$SUPPORT/user-state")" = "user state" ] && [ "$(defaults read "$PREFS_DOMAIN" showMenuBar)" = 0 ]'
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
    'wait_until rollback_cleaned 30'
  check "a late start of the new copy quits at once and does not update again" 'late_copy_quits'
  quit_all
fi

# ---------------------------------------------------------------------------------------------------------
if wants upgrade; then
  echo
  echo "Part 4: install-app.sh on a Mac with an older Zeus app and user data"
  # upgrade_case <name> <installed version>: the app in a simulated Applications folder, a home folder with
  # user data, and a simulated GitHub CLI. Git and the GitHub login are there; Anaconda installs (simulated).
  upgrade_case() {
    NAME="$1"
    SANDBOX="$WORK/$1/home"
    STATE="$WORK/$1/state"
    APPS="$WORK/$1/Applications"
    TRACE="$WORK/$1/trace.log"
    OUT="$WORK/$1/out"
    TEMP="$WORK/$1/tmp"
    SUPPORT="$SANDBOX/Library/Application Support/Zeus"
    mkdir -p "$SANDBOX/.local/bin" "$STATE/clt-dir/usr/bin" "$APPS" "$TEMP"
    ln -sf /usr/bin/git "$STATE/clt-dir/usr/bin/git"
    touch "$STATE/clt" "$STATE/gh-login"
    printf 'export PATH="%s:/usr/bin:/bin:/usr/sbin:/sbin"\n' "$SIM_DIR/stubs" >"$SANDBOX/.zprofile"
    cp "$SIM_DIR/payload/gh" "$SANDBOX/.local/bin/gh"
    # The user data: the Zeus folder and its client projects, the Zeus settings and app state, the Claude chats
    # and plugin data, and the saved window state.
    local zeus="$SANDBOX/Code/zeus" claude="$SANDBOX/.claude" saved="$SANDBOX/Library/Saved Application State/$BUNDLE_ID.savedState"
    mkdir -p "$zeus/.git" "$zeus/clients/acme/inbox" "$SUPPORT" "$claude/projects/-Users-sim-Code-zeus" \
      "$claude/plugins/data/zeus-editor" "$saved"
    echo "ref: refs/heads/main" >"$zeus/.git/HEAD"
    printf '# Acme\nOpen points for the next workshop.\n' >"$zeus/clients/acme/notes.md"
    head -c 4096 /dev/urandom >"$zeus/clients/acme/inbox/export.bin"
    printf '{"version": 1, "shortcuts": {"app.toggleTerminal": "Shift+Cmd+J"}}\n' >"$SUPPORT/settings.json"
    echo "user state" >"$SUPPORT/user-state"
    printf '{"type":"user","message":"Unsent idea: compare the Q3 throughput"}\n' >"$claude/projects/-Users-sim-Code-zeus/chat.jsonl"
    printf '{"enabledPlugins": {"zeus-editor@zeus-editor": true}}\n' >"$claude/settings.json"
    printf '{"tabs": 3}\n' >"$claude/plugins/data/zeus-editor/state.json"
    head -c 1024 /dev/urandom >"$saved/windows.plist"
    make_app "$2" "$APPS"
    defaults delete "$PREFS_DOMAIN" >/dev/null 2>&1 || true
    defaults write "$PREFS_DOMAIN" showMenuBar -bool false
    # Each case stops all its app copies after CASE_LIMIT seconds; quit_opened then reports the case as failed.
    stop_watchdog "$CASE_WATCHDOG"
    ( sleep "$CASE_LIMIT" >/dev/null 2>&1; touch "$WORK/$1/timed-out"; stop_copies "$APPS" ) &
    CASE_WATCHDOG=$!
  }
  # A checksum of every user data file, with its path.
  user_data() {
    (cd "$SANDBOX" && find Code .claude "Library/Application Support/Zeus" "Library/Saved Application State" -type f ! -name update.json -print0 |
      sort -z | xargs -0 shasum -a 256)
  }
  # The one-line install, stopped after 5 minutes. The app that it opens gets the test environment.
  install_line() {
    env HOME="$SANDBOX" TMPDIR="$TEMP" PATH="$SIM_DIR/stubs:/usr/bin:/bin:/usr/sbin:/sbin" \
      ZEUS_SIM_STATE="$STATE" ZEUS_SIM_PAYLOAD="$SIM_DIR/payload" ZEUS_SIM_INSTALLER="$REPO_DIR/install.sh" \
      ZEUS_INSTALL_SYSTEM_CONDA_DIRS="" ZEUS_INSTALL_ACCEPT_ANACONDA_LICENSE=yes ZEUS_APP_TRACE="$TRACE" \
      ZEUS_INSTALL_URL="file://$REPO_DIR/install.sh" ZEUS_APP_DIR="$APPS" \
      ZEUS_APP_OPEN_ENV="HOME ZEUS_APP_TRACE ZEUS_APP_TEST_ID ZEUS_APP_DEFAULTS_SUITE ZEUS_APP_TEST_BACKGROUND ZEUS_SIM_STATE ZEUS_SIM_PAYLOAD ZEUS_SIM_INSTALLER ZEUS_INSTALL_SYSTEM_CONDA_DIRS ZEUS_APP_NO_UPDATE ZEUS_APP_TEST_NO_CONFIRM" \
      "$@" bash "$REPO_DIR/install-app.sh" >"$OUT" 2>&1 &
    local pid=$! status=0 waited=0
    while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 600 ]; do sleep 0.5; waited=$((waited + 1)); done
    if kill -0 "$pid" 2>/dev/null; then
      echo "    (the install line did not end in 5 minutes)"
      pkill -P "$pid" 2>/dev/null || true
      kill "$pid" 2>/dev/null || true
    fi
    wait "$pid" || status=$?
    return "$status"
  }
  # ended <pid> [seconds]: waits until the process has ended (a process that ended but was not waited for counts).
  ended() {
    local waited=0 limit="${2:-10}"
    while ps -o stat= -p "$1" 2>/dev/null | grep -qv Z; do
      [ "$waited" -lt $((limit * 2)) ] || return 1
      sleep 0.5
      waited=$((waited + 1))
    done
  }
  # The inode of the app binary: a move keeps it, so the same inode is the same app bundle.
  app_inode() { stat -f %i "$APPS/Zeus.app/Contents/MacOS/Zeus" 2>/dev/null; }
  # Quits every copy of this case's app with the quit of the install line (quit_zeus_app in install.sh).
  # The test actions (act) do not reach every copy that macOS opens with "open".
  quit_opened() {
    # shellcheck source=install.sh
    if (export ZEUS_INSTALL_SOURCED=1 && source "$REPO_DIR/install.sh" && quit_zeus_app "$APPS") >/dev/null; then
      pass "the app quits"
    else
      fail "the app quits"
      stop_copies "$APPS"
    fi
    if [ -e "$WORK/$NAME/timed-out" ]; then fail "the case $NAME ends within ${CASE_LIMIT}s"; fi
    stop_watchdog "$CASE_WATCHDOG"
    CASE_WATCHDOG=""
  }
  # No old copy and no update.json are left.
  # The removal ends a little after the app's own confirmation or the end of the install line, so wait up to 20 s.
  settled() { local waited=0; until "$@"; do sleep 0.5; waited=$((waited + 1)); [ "$waited" -lt 40 ] || return 1; done; }
  no_update_files() { settled no_update_files_now; }
  no_update_files_now() { [ ! -e "$SUPPORT/update.json" ] && [ -z "$(ls -A "$TEMP" 2>/dev/null)" ]; }
  # After a roll back, the old app keeps update.json with "rolledBack" for 120 s on purpose (Updater.lateStartWindow).
  # No old copy is left, and update.json is absent or only that mark.
  no_update_files_after_rollback() { settled no_update_files_after_rollback_now; }
  no_update_files_after_rollback_now() {
    [ -z "$(ls -A "$TEMP" 2>/dev/null)" ] && { [ ! -e "$SUPPORT/update.json" ] || grep -q '"rolledBack":true' "$SUPPORT/update.json"; }
  }

  upgrade_case upgrade 1.0.0
  releases "$STATE" "app-v1.0.0:false:false" "app-v1.1.0:false:false"
  publish "$STATE" app-v1.1.0 1.1.0
  # The installed app is open. Like versions 0.1.0 to 0.1.2, it does not update itself.
  launch ZEUS_APP_NO_UPDATE=1
  OLD_PID="$APP_PID"
  wait_for "setup ended: check=true" 60 || true
  BEFORE="$(user_data)"
  check "with an older app installed and open, the install line ends without an error" 'install_line'
  check "it shows the installed and the newest version" \
    'grep -q "is version 1.0.0; the newest version is 1.1.0" "$OUT" && grep -q "The Zeus app is updated from 1.0.0 to 1.1.0." "$OUT"'
  check "it says that the projects, chats, and settings did not change" 'grep -q "Your projects, chats, and settings did not change." "$OUT"'
  check "the open app closes with its own quit (not killed)" \
    'ended "$OLD_PID" 10 && old_status=0 && { wait "$OLD_PID" || old_status=$?; } && [ "$old_status" = 0 ]'
  check "the new app starts and confirms its start" 'wait_for "update: confirmed 1.0.0 -> 1.1.0" 10 && grep -q "launched: version=1.1.0" "$TRACE"'
  check "the app in Applications is version 1.1.0 with a valid signature" \
    '[ "$(app_version "$APPS/Zeus.app")" = 1.1.0 ] && codesign --verify --strict "$APPS/Zeus.app"'
  check "the old app and update.json are removed after the confirmation" 'no_update_files'
  check "every user data file is unchanged" '[ -n "$BEFORE" ] && [ "$(user_data)" = "$BEFORE" ]'
  check "the app preferences are unchanged" '[ "$(defaults read "$PREFS_DOMAIN" showMenuBar)" = 0 ]'
  check "one copy of the app runs" '[ "$(copies)" = 1 ]'
  quit_opened

  upgrade_case current 1.1.0
  releases "$STATE" "app-v1.0.0:false:false" "app-v1.1.0:false:false"
  publish "$STATE" app-v1.1.0 1.1.0
  BEFORE="$(user_data)"
  INODE="$(app_inode)"
  check "with the newest app installed, the install line ends without an error" 'install_line'
  check "it says that the app is already the newest version" 'grep -q "The Zeus app is already the newest version (1.1.0)." "$OUT"'
  check "it downloads nothing and keeps the installed app" '! grep -q "release download" "$STATE/gh.log" && [ "$(app_inode)" = "$INODE" ]'
  check "it opens the app" 'wait_for "launched: version=1.1.0" 60'
  check "every user data file is unchanged" '[ -n "$BEFORE" ] && [ "$(user_data)" = "$BEFORE" ]'
  quit_opened

  upgrade_case rollback 1.0.0
  releases "$STATE" "app-v1.1.0:false:false"
  # A new app that stops at once.
  make_app 1.1.0 "$WORK/rollback/build"
  printf 'int main(void) { return 1; }\n' | xcrun clang -x c -o "$WORK/rollback/build/Zeus.app/Contents/MacOS/Zeus" -
  codesign --force --sign - "$WORK/rollback/build/Zeus.app" 2>/dev/null
  mkdir -p "$STATE/releases/app-v1.1.0"
  ditto -c -k --keepParent "$WORK/rollback/build/Zeus.app" "$STATE/releases/app-v1.1.0/Zeus.zip"
  (cd "$STATE/releases/app-v1.1.0" && shasum -a 256 Zeus.zip >Zeus.zip.sha256)
  BEFORE="$(user_data)"
  INODE="$(app_inode)"
  check "when the new app does not start, the install line stops with an error" '! install_line ZEUS_APP_NO_UPDATE=1'
  check "it says that the old app is back" 'grep -q "The Zeus app 1.1.0 did not start, so your Zeus app 1.0.0 is back." "$OUT"'
  check "the app in Applications is the old app again (version 1.0.0, same bundle, valid signature)" \
    '[ "$(app_version "$APPS/Zeus.app")" = 1.0.0 ] && [ "$(app_inode)" = "$INODE" ] && codesign --verify --strict "$APPS/Zeus.app"'
  check "no old copy is left, and update.json is absent or only the roll back mark" 'no_update_files_after_rollback'
  check "it opens the old app" 'wait_for "launched: version=1.0.0" 60'
  check "every user data file is unchanged" '[ -n "$BEFORE" ] && [ "$(user_data)" = "$BEFORE" ]'
  quit_opened

  upgrade_case noconfirm 1.0.0
  releases "$STATE" "app-v1.1.0:false:false"
  publish "$STATE" app-v1.1.0 1.1.0
  BEFORE="$(user_data)"
  INODE="$(app_inode)"
  echo "  (the new app starts but does not confirm; the install line waits 60 s)"
  check "when the new app runs but does not confirm its start, the install line stops with an error" \
    '! install_line ZEUS_APP_NO_UPDATE=1 ZEUS_APP_TEST_NO_CONFIRM=1'
  check "the new app started without a confirmation" 'grep -q "launched: version=1.1.0" "$TRACE" && grep -q "update: not confirmed (test)" "$TRACE"'
  check "it says that the old app is back" 'grep -q "The Zeus app 1.1.0 did not start, so your Zeus app 1.0.0 is back." "$OUT"'
  check "the app in Applications is the old app again (version 1.0.0, same bundle, valid signature)" \
    '[ "$(app_version "$APPS/Zeus.app")" = 1.0.0 ] && [ "$(app_inode)" = "$INODE" ] && codesign --verify --strict "$APPS/Zeus.app"'
  check "no old copy is left, and update.json is absent or only the roll back mark" 'no_update_files_after_rollback'
  check "the new app is stopped and the old app opens" 'wait_for "launched: version=1.0.0" 60 && [ "$(copies)" = 1 ]'
  check "every user data file is unchanged" '[ -n "$BEFORE" ] && [ "$(user_data)" = "$BEFORE" ]'
  quit_opened
fi

# ---------------------------------------------------------------------------------------------------------
if wants settings; then
  echo
  echo "Part 5: the update from the settings of a Zeus page"
  REAL_NODE="$(command -v node)"
  # wanted_case <name>: ZEUS_UPDATE_TEST_CASES (case names, separated by spaces) runs only those cases of this part.
  wanted_case() { [ -z "${ZEUS_UPDATE_TEST_CASES:-}" ] || case " $ZEUS_UPDATE_TEST_CASES " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
  # chat_case <name> <installed version>: an app case after the Zeus setup, with a simulated zeus that serves a chat page.
  chat_case() {
    app_case "$1" "$2"
    mkdir -p "$SANDBOX/Code/zeus"
    printf '#!/bin/sh\nexec "%s" "%s" "$@"\n' "$REAL_NODE" "$SIM_DIR/payload/zeus.mjs" >"$SANDBOX/.local/bin/zeus"
    chmod +x "$SANDBOX/.local/bin/zeus"
    defaults write "$PREFS_DOMAIN" setupDone -bool true
  }
  act() { "$BIN/act" "$1"; }
  # wait_count <trace pattern> <count> [seconds]
  wait_count() {
    local pattern="$1" count="$2" limit="${3:-60}" waited=0 found
    while found="$(grep -c -- "$pattern" "$TRACE" 2>/dev/null || true)"; [ "${found:-0}" -lt "$count" ]; do
      sleep 0.5
      waited=$((waited + 1))
      if [ "$waited" -ge $((limit * 2)) ]; then echo "    (timed out waiting for $count x: $pattern)"; return 1; fi
    done
  }
  # update_page_has <text>...: the chat page of the last tab writes its last update event into the trace, and it has each text.
  # page_has <text>: the page has window.zeusApp.update with this text.
  page_has() {
    local before
    before="$(grep -c "update page: " "$TRACE" || true)"
    act test-update-page
    wait_count "update page: " $((before + 1)) 10 >/dev/null && grep "update page: " "$TRACE" | tail -1 | grep -qF -- "$1"
  }
  update_page_has() {
    local before line text
    before="$(grep -c "update page: " "$TRACE" || true)"
    act test-update-page
    wait_count "update page: " $((before + 1)) 10 >/dev/null || return 1
    line="$(grep "update page: " "$TRACE" | tail -1 | sed 's/.*"events":\[//; s/.*},{//')"
    for text in "$@"; do printf '%s' "$line" | grep -qF -- "$text" || { echo "    (no $text in: $line)"; return 1; }; done
  }
  # Tabs with unsent text make the quit ask first; a quit of macOS (log out) asks nothing.
  quit_chats() {
    local waited=0
    act quit
    while [ "$(copies)" != 0 ] && ! grep -q "quit deferred" "$TRACE" && [ "$waited" -lt 40 ]; do sleep 0.5; waited=$((waited + 1)); done
    if grep -q "quit deferred" "$TRACE"; then act test-power-off; fi
    quit_all
  }
  sessions_with() { grep -c " $1 " "$STATE/sessions" 2>/dev/null || true; }
  # The session ids that the first copy's sessions had, in the order they started.
  first_ids() { grep " session " "$STATE/sessions" | head -"$1" | awk '{print $3}' | sort | tr '\n' ' '; }
  resumed_ids() { grep " resume " "$STATE/sessions" | awk '{print $3}' | sort | tr '\n' ' '; }
  three_stopped() { [ "$(sessions_with stop)" = 3 ]; }
  # The text came in as terminal input of a resumed session, without Enter.
  resumed_terminal_has() {
    local pid
    for pid in $(grep " resume " "$STATE/sessions" | awk '{print $1}'); do
      grep -q "^$pid input $(printf %s "$1" | xxd -p)$" "$STATE/sessions" && return 0
    done
    return 1
  }
  # Three tabs: Solvias with the tab name "Solvias QA"; unsent text in the message box; a busy turn, an open
  # terminal, and unsent text in the terminal.
  three_tabs() {
    wait_count "state: running" 1 60 && wait_count "hand-over" 1 30 || return 1
    act test-pick-project:Solvias
    act test-rename-open
    act "test-rename-save:Solvias QA"
    act new-chat
    wait_count "state: running" 2 60 && wait_count "hand-over" 2 30 || return 1
    act test-draft
    act new-chat
    wait_count "state: running" 3 60 && wait_count "hand-over" 3 30 || return 1
    act toggle-terminal
    sleep 1
    act "test-terminal-type:ls -la"
    act test-draft
    act test-send
    sleep 0.5
    act test-draft
  }

  if wanted_case settings; then
    chat_case settings 1.0.0
    releases "$STATE" "app-v1.0.0:false:false"
    launch ZEUS_SIM_TURN_MS=8000
    check "the app is up to date at launch and opens the chat" 'wait_for "update: none (up to date)" 60 && wait_count "state: running" 1 60'
    check "every Zeus page has window.zeusApp.update" 'wait_count "hand-over" 1 30 && page_has "{\"version\":1,"'
    act 'test-post:{"type":"app-update-check"}'
    check "Check for updates: the page gets the newest app release and no update" \
      'wait_for "app update: answer 1.0.0 available=false" 30 && update_page_has "\"type\":\"app-update\"" "\"current\":\"1.0.0\"" "\"latest\":\"1.0.0\"" "\"notes\":null" "\"available\":false"'
    releases "$STATE" "app-v1.0.0:false:false" "app-v1.1.0:false:false" "app-v1.2.0:true:false"
    publish "$STATE" app-v1.1.0 1.1.0
    act 'test-post:{"type":"app-update-check"}'
    check "after a new release, the page gets its version and its notes (not drafts)" \
      'wait_for "app update: answer 1.1.0 available=true" 30 && update_page_has "\"latest\":\"1.1.0\"" "\"notes\":\"Zeus 1.1.0\\n\\nnotes\"" "\"available\":true"'
    check "the check downloads nothing" '! grep -q "release download" "$STATE/gh.log"'
    check "three tabs open: a project with a tab name, unsent text, and a busy turn with unsent terminal text" 'three_tabs'
    act 'test-post:{"type":"app-update-apply"}'
    check "Update now downloads and checks the new version" 'wait_for "app update: progress downloading" 60 && wait_for "update: downloading app-v1.1.0" 60'
    check "the update waits for the busy tab" 'wait_for "app update: waiting for 1 busy tabs" 60 && ! grep -q "update: ending" "$TRACE"'
    check "the pages get the progress" 'update_page_has "\"type\":\"app-update-progress\"" "\"state\":\"waiting\"" "\"version\":\"1.1.0\"" "\"busy\":1"'
    check "the turn ends before the update goes on" 'wait_for "update: ending 3 tabs for 1.1.0" 60 && [ "$(sessions_with reply)" = 1 ]'
    check "it keeps each tab's session, project, name, and unsent text" \
      'grep -q "snapshot: .* project=Solvias draft=0 terminal-draft=0" "$TRACE" && grep -q "snapshot: .* draft=14 terminal-draft=0" "$TRACE" &&
       grep -q "snapshot: .* draft=14 terminal-draft=6" "$TRACE" && [ "$(grep -c "snapshot: .* session=[0-9a-f-]\{36\}" "$TRACE")" = 3 ]'
    check "it shows the loading screen while it installs" 'grep -q "update window: Installing Zeus 1.1.0…" "$TRACE"'
    check "it ends every session of the old copy" 'wait_until three_stopped 30'
    check "the new copy starts and confirms the update" 'wait_for "update: confirmed 1.0.0 -> 1.1.0" 120 && wait_for "update: done 1.0.0 -> 1.1.0" 120'
    check "the app is now version 1.1.0 and the old copy has quit" \
      '[ "$(app_version "$APPS/Zeus.app")" = 1.1.0 ] && sleep 1 && ! kill -0 "$APP_PID" 2>/dev/null && grep -q "launched: version=1.1.0" "$TRACE"'
    check "the new copy opens the same three tabs" 'wait_for "restore: 3 tabs in 1 windows" 60 && wait_count "state: running" 6 60'
    check "each tab resumes its own Claude Code session" 'wait_count "resume=.* ok" 3 60 && [ "$(resumed_ids)" = "$(first_ids 3)" ]'
    check "the tab keeps its project and its name" 'wait_for "tab name: Solvias QA project=Solvias custom=Solvias QA" 30 && [ "$(grep -c "tab name: Solvias QA project=Solvias custom=Solvias QA" "$TRACE")" -ge 2 ]'
    check "the unsent text goes back into the message boxes" 'wait_count "message box text back=true" 2 60'
    check "the unsent terminal text goes back into the terminal, without Enter" \
      'wait_for "terminal text back" 60 && sleep 1 && resumed_terminal_has "ls -la"'
    check "the restore file is removed" '[ ! -e "$SUPPORT/restore.json" ] && [ ! -e "$SUPPORT/update.json" ]'
    check "one copy of the app runs" '[ "$(copies)" = 1 ]'
    quit_chats
  fi

  if wanted_case settings-current; then
    chat_case settings-current 1.1.0
    releases "$STATE" "app-v1.1.0:false:false"
    launch
    check "an app that is up to date opens the chat" 'wait_for "update: none (up to date)" 60 && wait_count "state: running" 1 60 && wait_count "hand-over" 1 30'
    act 'test-post:{"type":"app-update-apply"}'
    check "Update now says that the app is on the latest version and changes nothing" \
      'wait_for "app update: none (up to date)" 30 && update_page_has "\"type\":\"app-update-failed\"" "\"error\":\"up-to-date\"" &&
       [ "$(sessions_with stop)" = 0 ] && [ "$(app_version "$APPS/Zeus.app")" = 1.1.0 ]'
    quit_chats
  fi

  if wanted_case settings-noaccess; then
    chat_case settings-noaccess 1.0.0
    releases "$STATE" "app-v1.0.0:false:false"
    launch
    check "without access, the app opens the chat" 'wait_count "state: running" 1 60 && wait_count "hand-over" 1 30'
    rm "$STATE/releases.json"
    act 'test-post:{"type":"app-update-check"}'
    check "Check for updates without an answer from GitHub says so" \
      'wait_for "app update: answer - available=false error=unreachable" 30 && update_page_has "\"error\":\"unreachable\""'
    quit_chats
  fi

  # A tab that still starts (its chat page is not shown yet) counts as busy: the update waits until it shows its chat,
  # so the snapshot has its session and the new copy resumes it.
  if wanted_case settings-starting; then
    chat_case settings-starting 1.0.0
    releases "$STATE" "app-v1.0.0:false:false"
    launch ZEUS_SIM_START_DELAY=10000
    check "the app opens the chat" 'wait_for "update: none (up to date)" 60 && wait_count "state: running" 1 60 && wait_count "hand-over" 1 60'
    releases "$STATE" "app-v1.0.0:false:false" "app-v1.1.0:false:false"
    publish "$STATE" app-v1.1.0 1.1.0
    act new-chat
    check "a second tab starts" 'wait_count "tab selected: " 2 30 && [ "$(grep -c "state: running" "$TRACE")" = 1 ]'
    act 'test-post:{"type":"app-update-apply"}'
    check "the update waits for the tab that still starts" \
      'wait_for "app update: waiting for 1 busy tabs" 60 && ! grep -q "update: ending" "$TRACE"'
    check "the update goes on only after the tab shows its chat" \
      'wait_for "update: ending 2 tabs for 1.1.0" 60 && [ "$(grep -c "hand-over" "$TRACE")" -ge 2 ] &&
       [ "$(grep -c "snapshot: .* session=[0-9a-f-]\{36\}" "$TRACE")" = 2 ]'
    check "the new copy resumes the sessions of both tabs" \
      'wait_for "update: confirmed 1.0.0 -> 1.1.0" 120 && wait_for "restore: 2 tabs in 1 windows" 60 &&
       wait_count "resume=.* ok" 2 90 && [ "$(resumed_ids)" = "$(first_ids 2)" ]'
    quit_chats
  fi

  if wanted_case settings-rollback; then
    chat_case settings-rollback 1.0.0
    releases "$STATE" "app-v1.0.0:false:false"
    launch ZEUS_APP_TEST_NO_CONFIRM=1
    check "the app opens the chat" 'wait_for "update: none (up to date)" 60 && wait_count "state: running" 1 60'
    releases "$STATE" "app-v1.0.0:false:false" "app-v1.1.0:false:false"
    publish "$STATE" app-v1.1.0 1.1.0
    check "two tabs open, one with unsent text" 'wait_count "hand-over" 1 30 && act new-chat && wait_count "state: running" 2 60 && wait_count "hand-over" 2 30 && act test-draft'
    act 'test-post:{"type":"app-update-apply"}'
    check "when the new copy does not confirm, the old copy is put back" 'wait_for "update: rolled back to 1.0.0" 120'
    check "the old copy opens the same tabs again, with their sessions and unsent text" \
      'wait_for "update: tabs open again after the failed update to 1.1.0" 30 && wait_count "resume=.* ok" 2 60 && [ "$(resumed_ids)" = "$(first_ids 2)" ] &&
       wait_count "message box text back=true" 1 60'
    check "the app in Applications is version 1.0.0 again, and the old copy runs" \
      '[ "$(app_version "$APPS/Zeus.app")" = 1.0.0 ] && kill -0 "$APP_PID" 2>/dev/null'
    check "the new copy was stopped and the update files are removed" 'wait_until rollback_cleaned 30 && [ ! -e "$SUPPORT/restore.json" ]'
    check "a late start of the new copy quits at once and does not update again" 'late_copy_quits'
    quit_chats
  fi
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  printf '\033[32mAll checks passed.\033[0m\n'
else
  printf '\033[31m%s checks failed.\033[0m\n' "$FAILURES"
  exit 1
fi
