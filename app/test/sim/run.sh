#!/bin/bash
# End-to-end test of Zeus.app and install.sh on a simulated new Mac.
#
# The app runs with HOME set to an empty temporary folder and with simulated tools (xcode-select,
# curl, shasum, conda, gh, npm, claude, zeus) first on PATH, so nothing is downloaded and the real
# home folder, Claude Code, and GitHub login are not used. The test presses the app's buttons through
# its debug test actions (active only with ZEUS_APP_TRACE) and checks the trace.
#
# Usage: app/test/sim/run.sh [screenshot-folder]
# With a folder, it saves a screenshot of each app window state there (the app's windows only).
set -euo pipefail

SIM_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$SIM_DIR/../.." && pwd)"
REPO_DIR="$(dirname "$APP_DIR")"
SHOTS="${1:-}"
BUNDLE_ID="io.github.theo-henry.zeus"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/zeus-sim.XXXXXX")"
BIN="$WORK/bin"
# Test actions reach only the app copy that this test starts, not another running Zeus app.
export ZEUS_APP_TEST_ID="sim-$$"
mkdir -p "$BIN"
[ -n "$SHOTS" ] && mkdir -p "$SHOTS"

FAILURES=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

# Helpers: send a test action to the app, and list the app's windows.
cat >"$WORK/act.swift" <<'SWIFT'
import Foundation
let testID = ProcessInfo.processInfo.environment["ZEUS_APP_TEST_ID"].map { "." + $0 } ?? ""
DistributedNotificationCenter.default().postNotificationName(Notification.Name("io.github.theo-henry.zeus.test" + testID),
    object: CommandLine.arguments[1], userInfo: nil, deliverImmediately: true)
SWIFT
cat >"$WORK/windows.swift" <<'SWIFT'
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let pid = Int(CommandLine.arguments[1]) ?? -1
for w in list where (w[kCGWindowOwnerPID as String] as? Int) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
    print(w[kCGWindowNumber as String] ?? 0, w[kCGWindowName as String] ?? "")
}
SWIFT
# The quit Apple event that loginwindow sends to each app when macOS logs out.
cat >"$WORK/logout.swift" <<'SWIFT'
import Foundation
let target = NSAppleEventDescriptor(processIdentifier: pid_t(CommandLine.arguments[1])!)
let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEQuitApplication),
    targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
event.setParam(NSAppleEventDescriptor(enumCode: OSType(kAEReallyLogOut)), forKeyword: AEKeyword(kAEQuitReason))
do { _ = try event.sendEvent(options: [.noReply], timeout: 5) } catch { print("logout event not sent: \(error)") }
SWIFT
swiftc -O -o "$BIN/act" "$WORK/act.swift" 2>/dev/null
swiftc -O -o "$BIN/logout" "$WORK/logout.swift" 2>/dev/null
swiftc -O -o "$BIN/windows" "$WORK/windows.swift" 2>/dev/null

echo "Building the development app"
APP="$("$APP_DIR/dev-bundle.sh" 2>/dev/null | tail -1)"
EXE="$APP/Contents/MacOS/Zeus"

REAL_NODE="$(command -v node)"
PREFS_BACKUP="$WORK/prefs.plist"
defaults export "$BUNDLE_ID" "$PREFS_BACKUP" 2>/dev/null || rm -f "$PREFS_BACKUP"
APP_PID=""

cleanup() {
  [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null || true
  defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  [ -f "$PREFS_BACKUP" ] && defaults import "$BUNDLE_ID" "$PREFS_BACKUP"
  rm -rf "$WORK"
}
trap cleanup EXIT

# Sends a test action to this test's copy of the app only.
act() { "$BIN/act" "@$APP_PID $1"; }

shot() {
  [ -n "$SHOTS" ] || return 0
  sleep 0.8
  local id
  id="$("$BIN/windows" "$APP_PID" | head -1 | awk '{print $1}')"
  [ -n "$id" ] && screencapture -x -o -l "$id" "$SHOTS/$1.png"
}

# wait_for <trace pattern> [seconds]
wait_for() {
  local pattern="$1" limit="${2:-60}" waited=0
  until grep -q -- "$pattern" "$TRACE" 2>/dev/null; do
    sleep 0.5
    waited=$((waited + 1))
    if [ "$waited" -ge $((limit * 2)) ]; then
      echo "    (timed out waiting for: $pattern)"
      return 1
    fi
  done
}

# wait_count <trace pattern> <count> [seconds]
wait_count() {
  local pattern="$1" count="$2" limit="${3:-60}" waited=0
  until [ "$(grep -c -- "$pattern" "$TRACE" 2>/dev/null || true)" -ge "$count" ]; do
    sleep 0.5
    waited=$((waited + 1))
    if [ "$waited" -ge $((limit * 2)) ]; then
      echo "    (timed out waiting for $count x: $pattern)"
      return 1
    fi
  done
}

stops() { grep -c " stop " "$STATE/sessions" 2>/dev/null || true; }

# wait_starts <count>: waits until that many simulated zeus sessions have started.
wait_starts() {
  local waited=0
  until [ "$(grep -c " start " "$STATE/sessions" 2>/dev/null || true)" -ge "$1" ]; do
    sleep 0.5
    waited=$((waited + 1))
    [ "$waited" -lt 40 ] || return 1
  done
}

# start_app <name> [extra env...]
start_app() {
  local name="$1"
  SANDBOX="$WORK/$name/home"
  STATE="$WORK/$name/state"
  mkdir -p "$SANDBOX" "$STATE"
  # A new Mac: no tools in the home folder, and the simulated tools before the system ones.
  printf 'export PATH="%s:/usr/bin:/bin:/usr/sbin:/sbin"\n' "$SIM_DIR/stubs" >"$SANDBOX/.zprofile"
  defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  launch_app "$@"
}

# launch_app <name> [extra env...]: starts the app again in the current simulated home folder.
launch_app() {
  local name="$1"
  shift
  TRACE="$WORK/$name/trace.log"
  mkdir -p "$WORK/$name"
  env HOME="$SANDBOX" ZEUS_APP_TRACE="$TRACE" \
    ZEUS_SIM_STATE="$STATE" ZEUS_SIM_PAYLOAD="$SIM_DIR/payload" ZEUS_SIM_REAL_NODE="$REAL_NODE" \
    ZEUS_SIM_INSTALLER="$REPO_DIR/install.sh" ZEUS_INSTALL_SYSTEM_CONDA_DIRS="" "$@" \
    "$EXE" >"$WORK/$name/app.out" 2>&1 &
  APP_PID=$!
}

stop_app() {
  act quit
  local waited=0
  while kill -0 "$APP_PID" 2>/dev/null && [ "$waited" -lt 40 ]; do sleep 0.5; waited=$((waited + 1)); done
  kill -0 "$APP_PID" 2>/dev/null && { fail "the app quits"; kill "$APP_PID"; } || pass "the app quits"
  APP_PID=""
  if [ -n "$SHOTS" ]; then cp "$TRACE" "$SHOTS/trace-$(basename "$(dirname "$TRACE")").log"; fi
}

echo
echo "Scenario 1: a new Mac, full setup, chat, close"
start_app new ZEUS_SIM_START_DELAY=2500
check "the setup window opens and checks this Mac" 'wait_for "setup ended: check=true code=0" 30'
todo="$(grep -c 'setup event: state [0-9]* todo' "$TRACE" || true)"
check "the check finds 12 steps to do on a new Mac (got $todo)" '[ "$todo" = 12 ]'
shot 1-check

act setup-install
check "step 1: the Xcode tools install (simulated system window)" 'wait_for "setup event: done 1 " 40'
check "step 2: the installer asks for the Anaconda license" 'wait_for "setup event: ask 2 " 20'
shot 2-anaconda-license
act setup-answer-yes
check "step 2: Anaconda installs after Accept" 'wait_for "setup event: done 2 " 30'
check "step 3: the GitHub CLI installs" 'wait_for "setup event: done 3 " 30'
check "step 4: the GitHub login starts" 'wait_for "setup event: running 4 " 10'
sleep 2
shot 3-github-code
act setup-enter
check "step 4: the GitHub login completes after Open GitHub" 'wait_for "setup event: done 4 " 20'
check "step 5: access to the Zeus repos" 'wait_for "setup event: done 5 " 20'
check "step 6: Node.js installs" 'wait_for "setup event: done 6 " 30'
check "step 7: Claude Code installs" 'wait_for "setup event: done 7 " 30'
check "step 8: content-cli installs" 'wait_for "setup event: done 8 " 30'
check "step 9: the Zeus workspace is cloned" 'wait_for "setup event: done 9 " 30'
check "step 10: the Zeus Editor plugin installs" 'wait_for "setup event: done 10 " 30'
check "step 11: the zeus command installs" 'wait_for "setup event: done 11 " 30'
check "step 12: the Zeus skill plugins install" 'wait_for "setup event: done 12 " 30'
check "step 13: the Claude login starts" 'wait_for "setup event: running 13 " 10'
sleep 1.5
shot 4-claude-login
check "step 13: the Claude login completes" 'wait_for "setup event: done 13 " 30'
check "the setup finishes" 'wait_for "setup ended: check=false code=0" 20'
shot 5-finished
check "the installer wrote only into the simulated home folder" '[ -x "$SANDBOX/.local/bin/zeus" ] && [ -d "$SANDBOX/Code/zeus/.git" ]'

act setup-start
if [ -n "$SHOTS" ]; then
  sleep 0.3
  shot 6-startup
  video_id="$("$BIN/windows" "$APP_PID" | head -1 | awk '{print $1}')"
  [ -z "$video_id" ] || { rm -f "$SHOTS/startup.mov"; screencapture -x -v -V 4 -l "$video_id" "$SHOTS/startup.mov"; }
fi
check "Start Zeus starts a hidden zeus session" 'wait_for "state: running(" 30'
check "the chat page loads in the app window" 'wait_for "page loaded: http://127.0.0.1" 20'
check "the first chat gets the globe hand-over" 'wait_for "hand-over: globe moves to" 10'
check "zeus runs in ~/Code/zeus with --no-open" 'grep -q "\"--no-open\"" "$STATE/zeus-started" && grep -q "/Code/zeus\"" "$STATE/zeus-started"'
shot 6-chat
# A close with draft text must preserve the same WebView and PTY.
act test-draft
sleep 0.5
act close-chat
check "draft text defers tab close" 'wait_for "close deferred: .* composer-draft" 10'
check "draft session is still running" '[ ! -f "$STATE/zeus-stopped" ]'
shot 7-draft-close
act test-cancel-close
check "a pending close can be cancelled" 'wait_for "close cancelled:" 10'
act test-clear
sleep 1
check "cancelled close keeps the tab alive" '[ ! -f "$STATE/zeus-stopped" ]'
act close-chat
check "clearing the draft completes the pending close" 'wait_for "state: ended" 20'
check "zeus got SIGTERM" '[ "$(cat "$STATE/zeus-stopped" 2>/dev/null)" = SIGTERM ]'

# New tabs must own different PTYs; terminal input must reach only the selected PTY.
act test-cmd-t
sleep 4
act test-cmd-t
sleep 4
check "each new tab starts a separate PTY" '[ "$(grep -c " start " "$STATE/sessions")" = 3 ]'
check "later tabs come in at once, without the globe hand-over" '[ "$(grep -c "hand-over: at once" "$TRACE")" = 2 ] && [ "$(grep -c "hand-over: globe moves" "$TRACE")" = 1 ]'
# Tab names: the project of the chat, until the user renames the tab. The app does not keep them.
check "a new tab without a project is named Project" 'grep "tab selected: " "$TRACE" | tail -1 | grep -q " Project$"'
wait_count "state: running(" 3 20 >/dev/null && sleep 1
act test-pick-project:Solvias
check "a project picked in the chat names the tab" 'wait_for "tab name: Solvias project=Solvias custom=-" 10'
act test-rename-open
shot 8-tab-names
act "test-rename-save:Solvias QA"
check "a renamed tab shows the new name" 'wait_for "tab name: Solvias QA project=Solvias custom=Solvias QA" 10'
act test-pick-project:Vicat
check "a renamed tab keeps its name when the project changes" 'wait_for "tab name: Solvias QA project=Vicat custom=Solvias QA" 10'
act test-rename-open
act test-rename-save:
check "an empty name gives the tab the project name again" 'wait_for "tab name: Vicat project=Vicat custom=-" 10'
act "test-pick-project:No project"
check "a tab without a project is named Project again" 'wait_for "tab name: Project project=- custom=-" 10'
act test-cmd-j
check "the per-tab terminal opens" 'wait_for "terminal visible: .* true" 10'
act test-terminal-input
sleep 1
check "xterm input reaches the live PTY" 'grep -q "input 7465726d696e616c2d746573740a" "$STATE/sessions"'
shot 8-terminal-tabs
act test-draft
sleep 0.3
act test-send
sleep 0.3
act close-chat
check "busy work defers tab close" 'wait_for "close deferred: .* busy" 10'
shot 9-busy-close
check "the chat turn completes before its PTY stops" 'wait_for "state: ended" 20 && sleep 4 && grep -q "reply Test chat turn" "$STATE/sessions"'
check "closing one tab preserves the other PTY" '[ "$(grep -c " stop " "$STATE/sessions")" = 2 ]'
act close-chat
sleep 2
check "an idle tab closes its PTY" '[ "$(grep -c " stop " "$STATE/sessions")" = 3 ]'

# A chat that cannot answer the close check (an editor plugin older than the app) must not block the close forever.
touch "$STATE/no-close-state"
act test-cmd-t
check "a tab with an older editor plugin starts" 'wait_starts 4'
rm -f "$STATE/no-close-state"
check "its chat page opens" 'wait_count "state: running(" 4 20 && sleep 2'
act close-chat
sleep 1.5
check "an unanswered close check first waits and keeps the PTY" '! grep -q "close deferred: .* unavailable" "$TRACE" && [ "$(stops)" = 3 ]'
check "an unanswered close check then offers Close anyway" 'wait_for "close deferred: .* unavailable" 10'
shot 10-unavailable-close
sleep 1
check "the tab stays open until the user decides" '[ "$(stops)" = 3 ]'
act test-close-anyway
check "Close anyway closes the tab that cannot answer" 'wait_count "state: ended" 4 10 && [ "$(stops)" = 4 ]'

# Close anyway must also override a busy chat.
act test-cmd-t
check "a new tab opens after Close anyway" 'wait_count "state: running(" 5 20 && sleep 2'
act test-draft
sleep 0.3
act test-send
sleep 0.3
act close-chat
check "busy work defers the close of the new tab" 'wait_count "close deferred: .* busy" 2 10'
shot 11-busy-close-anyway
act test-close-anyway
check "Close anyway stops a busy tab before its turn ends" 'wait_count "state: ended" 5 10 && [ "$(stops)" = 5 ] && [ "$(grep -c " reply " "$STATE/sessions")" = 1 ]'

act test-cmd-t
sleep 4
act test-cmd-t
sleep 4
stop_app
check "quit stops every remaining PTY" '[ "$(stops)" = 7 ]'

echo
echo "Scenario 2: a cancelled logout, then a quit and a logout while one tab has a draft and one tab is busy"
defaults write "$BUNDLE_ID" setupDone -bool true
launch_app logout
check "the app opens a chat at once after the setup" 'wait_for "page loaded: http://127.0.0.1" 30'
act test-draft
act test-cmd-t
check "a second tab opens" 'wait_count "state: running(" 2 20 && sleep 2'
act test-draft
sleep 0.3
act test-send
sleep 0.5
# A logout that another app cancels: macOS warns of the power off, but no quit follows.
act test-power-off
check "a power-off warning alone stops nothing" 'wait_for "macOS powers off" 10 && sleep 1 && [ "$(stops)" = 7 ]'
act quit
check "a later quit still asks about the unsafe tabs" 'wait_for "quit deferred: " 10 && grep "quit deferred: " "$TRACE" | grep -q composer-draft && grep "quit deferred: " "$TRACE" | grep -q busy'
shot 12-quit-question
# A real logout: macOS first warns of the power off, then sends the quit event.
logout_start=$(date +%s)
act test-power-off
"$BIN/logout" "$APP_PID"
waited=0
while kill -0 "$APP_PID" 2>/dev/null && [ "$waited" -lt 30 ]; do sleep 0.5; waited=$((waited + 1)); done
logout_time=$(($(date +%s) - logout_start))
kill -0 "$APP_PID" 2>/dev/null && kill "$APP_PID"
APP_PID=""
if [ -n "$SHOTS" ]; then cp "$TRACE" "$SHOTS/trace-logout.log"; fi
check "a logout during the quit question ends the quit within 12 s (took $logout_time s)" '[ "$logout_time" -le 12 ]'
check "the logout stops every PTY" '[ "$(stops)" = 9 ]'

# A logout quit event while a user quit still waits for a close check that does not answer (up to 3 s), and zeus
# takes 4 s to stop: the app asks nothing, also after the check ends.
touch "$STATE/hung-close-state"
launch_app logout-event ZEUS_SIM_STOP_DELAY=4000
check "the app opens a chat" 'wait_for "page loaded: http://127.0.0.1" 30'
rm -f "$STATE/hung-close-state"
act quit
sleep 1
logout_start=$(date +%s)
"$BIN/logout" "$APP_PID"
waited=0
while kill -0 "$APP_PID" 2>/dev/null && [ "$waited" -lt 30 ]; do sleep 0.5; waited=$((waited + 1)); done
logout_time=$(($(date +%s) - logout_start))
kill -0 "$APP_PID" 2>/dev/null && kill "$APP_PID"
APP_PID=""
if [ -n "$SHOTS" ]; then cp "$TRACE" "$SHOTS/trace-logout-event.log"; fi
check "the quit event of a logout ends the app within 12 s (took $logout_time s)" '[ "$logout_time" -le 12 ]'
check "the quit event of a logout asks nothing" 'grep -q "quit by macOS" "$TRACE" && ! grep -q "quit deferred" "$TRACE"'
check "the quit event of a logout stops the PTY" '[ "$(stops)" = 10 ]'

echo
echo "Scenario 3: the account has no access to one private repo"
start_app noaccess ZEUS_SIM_NO_ACCESS=theo-henry/celonis-pql
check "the setup window checks this Mac" 'wait_for "setup ended: check=true code=0" 30'
act setup-install
wait_for "setup event: ask 2 " 40 >/dev/null && act setup-answer-yes
wait_for "setup event: running 4 " 40 >/dev/null && sleep 1 && act setup-enter
check "step 5 fails and names the missing access" 'wait_for "setup event: failed 5 " 40'
check "the setup stops with an error" 'wait_for "setup ended: check=false code=1" 20'
shot 7-no-access
check "nothing after step 5 is installed" '[ ! -d "$SANDBOX/.local/node" ] && [ ! -d "$SANDBOX/Code/zeus" ]'
stop_app

echo
if [ "$FAILURES" -eq 0 ]; then
  printf '\033[32mAll checks passed.\033[0m\n'
else
  printf '\033[31m%s checks failed.\033[0m\n' "$FAILURES"
  exit 1
fi
