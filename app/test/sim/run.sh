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
# ZEUS_SIM_SCENARIOS="5 6" runs only the named scenarios (default: all; 2 and 3 run with 1, on its simulated Mac).

# check runs its test, in single quotes, with eval; ShellCheck does not see the variables in it.
# shellcheck disable=SC2016
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
SCENARIOS=" ${ZEUS_SIM_SCENARIOS:-1 4 5 6} "
runs() { case "$SCENARIOS" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
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
# The frame of the app's largest window with its sheets, for screenshots of a window with a sheet: "x,y,w,h".
cat >"$WORK/frame.swift" <<'SWIFT'
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let pid = Int(CommandLine.arguments[1]) ?? -1
let frames = list.filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
    .compactMap { $0[kCGWindowBounds as String] as! CFDictionary? }.compactMap { CGRect(dictionaryRepresentation: $0) }
if let largest = frames.max(by: { $0.width * $0.height < $1.width * $1.height }) {
    print("\(Int(largest.minX)),\(Int(largest.minY)),\(Int(largest.width)),\(Int(largest.height))")
}
SWIFT
swiftc -O -o "$BIN/windows" "$WORK/windows.swift" 2>/dev/null
swiftc -O -o "$BIN/frame" "$WORK/frame.swift" 2>/dev/null

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

# shot_frame <name>: the app's largest window with what lies on it (a sheet), as on the screen.
shot_frame() {
  [ -n "$SHOTS" ] || return 0
  sleep 0.8
  local frame
  frame="$("$BIN/frame" "$APP_PID")"
  [ -n "$frame" ] && screencapture -x -R"$frame" "$SHOTS/$1.png"
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
  until [ "$( (grep -c -- "$pattern" "$TRACE" 2>/dev/null || true) | head -1)" -ge "$count" ] 2>/dev/null; do
    sleep 0.5
    waited=$((waited + 1))
    if [ "$waited" -ge $((limit * 2)) ]; then
      echo "    (timed out waiting for $count x: $pattern)"
      return 1
    fi
  done
}

stops() { local n; n="$(grep -c " stop " "$STATE/sessions" 2>/dev/null)" || true; echo "${n:-0}"; }

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
  if kill -0 "$APP_PID" 2>/dev/null; then fail "the app quits"; kill "$APP_PID"; else pass "the app quits"; fi
  APP_PID=""
  if [ -n "$SHOTS" ]; then cp "$TRACE" "$SHOTS/trace-$(basename "$(dirname "$TRACE")").log"; fi
}

if runs 1; then
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
# "Go to the chat" in Zeus Editor: the chat page posts "chat-focus", and its tab (here the first, not selected) comes to the front.
act test-chat-focus
check "chat-focus brings the tab of that chat to the front" 'wait_for "chat focused: " 10 && pid="$(grep "chat focused: " "$TRACE" | tail -1 | awk "{print \$4}")" && grep "tab selected: " "$TRACE" | tail -1 | grep -q "tab selected: $pid "'
check "chat-focus puts the keyboard in the chat page" 'grep "chat focused: " "$TRACE" | tail -1 | grep -q "page-has-keyboard=true"'
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
echo "Scenario 3: speech to text in the chat and in Zeus Editor (simulated recognizer)"
launch_app speech ZEUS_APP_TEST_SPEECH=1
check "the app opens a chat" 'wait_for "page loaded: http://127.0.0.1" 30 && sleep 1'
# page_has <text>: the chat page (or with "editor-", the Zeus Editor page) writes its state into the trace, and it has this text.
page_has() {
  local before
  before="$(grep -c "speech page: " "$TRACE" || true)"
  act "test-${2:-}speech-page"
  wait_count "speech page: " $((before + 1)) 10 >/dev/null && grep "speech page: " "$TRACE" | tail -1 | grep -qF -- "$1"
}
check "the chat page can use speech to text, also after it sets window.zeusApp" 'page_has "\"version\":1,\"close\":\"function\""'
act 'test-speech-post:{"type":"speech-languages"}'
check "the languages are those on this Mac, with the default" 'sleep 1 && page_has "languages  en-US,fr-FR,nl-NL,de-DE/en-US"'
act test-draft
sleep 0.3
act 'test-speech-post:{"type":"speech-start","id":"s1","locale":"fr-FR"}'
check "a start listens" 'wait_for "speech event: state s1 listening" 10'
check "the words come in while the user speaks" 'wait_for "speech event: partial s1 chars=10" 10 && page_has "Test chat turnHello Zeus\""'
act 'test-speech-post:{"type":"speech-stop","id":"s1"}'
check "a stop gives the final text, then stopped" 'wait_for "speech event: state s1 stopped" 10'
check "the text replaces only the dictated part of the message" 'page_has "\"text\":\"Test chat turnHello Zeus.\""'
check "the page gets the events in order" 'page_has "\"state s1 listening\",\"partial s1 Hello\",\"partial s1 Hello Zeus\",\"final s1 Hello Zeus.\",\"state s1 stopped\""'
act 'test-speech-post:{"type":"speech-start","id":"s2","locale":null}'
check "a start with no language uses the default" 'wait_for "speech event: state s2 listening" 10 && grep -q "speech: start s2 locale=default" "$TRACE"'
act 'test-speech-post:{"type":"speech-start","id":"s3","locale":"en-US"}'
check "a second start while one runs is busy" 'sleep 0.5 && page_has "error s3 busy" && ! grep -q "speech event: state s3" "$TRACE"'
act test-cmd-t
check "showing another tab stops speech to text in the tab that the user leaves" 'wait_for "speech: stop s2 (tab hidden)" 10 && wait_for "speech event: state s2 stopped" 10'
check "the new tab opens" 'wait_count "state: running(" 2 20 && sleep 2'
act 'test-speech-post:{"type":"speech-start","id":"s4","locale":"ja-JP"}'
check "a language without recognition on the Mac gives no-on-device" 'wait_for "speech event: error s4 no-on-device" 10 && sleep 0.5 && ! grep -q "speech event: state s4" "$TRACE"'
act test-open-editor
check "a Zeus Editor page opens" 'wait_for "page loaded: http://127.0.0.1:[0-9]*/editor" 10'
check "the Zeus Editor page can use speech to text" 'page_has "\"version\":1" editor-'
act 'test-editor-speech-post:{"type":"speech-start","id":"e1","locale":"de-DE"}'
check "speech to text runs in the Zeus Editor page" 'wait_for "speech event: partial e1 chars=10" 10 && page_has "\"text\":\"Hello Zeus\"" editor-'
act 'test-speech-post:{"type":"speech-stop","id":"e1"}'
check "another page cannot stop it" 'sleep 0.5 && ! grep -q "speech: stop e1" "$TRACE"'
act test-close-editor
check "closing the Zeus Editor window ends it" 'wait_for "speech: cancel e1 (window closed)" 10'
act 'test-speech-post:{"type":"speech-start","id":"s5","locale":"nl-NL"}'
check "speech to text starts again after a cancel" 'wait_for "speech event: state s5 listening" 10'
act close-chat
act test-close-anyway
check "closing the tab ends it" 'wait_for "speech: cancel s5 (tab closed)" 10 && ! grep -q "speech event: final s5" "$TRACE"'
act test-clear
sleep 0.5
act test-open-editor
check "a Zeus Editor page opens again" 'wait_count "page loaded: http://127.0.0.1:[0-9]*/editor" 2 10'
act 'test-editor-speech-post:{"type":"speech-start","id":"e2","locale":"en-US"}'
check "speech to text runs in Zeus Editor before the quit" 'wait_for "speech event: state e2 listening" 10'
stop_app
check "quitting the app ends it" 'grep -q "speech: cancel e2 (app quits)" "$TRACE"'
# Apple's recognizer of this Mac: the language list and a language that no Mac knows need no permission question.
launch_app speech-apple
check "the app opens a chat with Apple's speech recognition" 'wait_for "page loaded: http://127.0.0.1" 30 && sleep 1'
act 'test-speech-post:{"type":"speech-languages"}'
check "Apple's recognizer lists the languages of this Mac and a default" 'sleep 3 && page_has "\"languages  "'
act 'test-speech-post:{"type":"speech-start","id":"a1","locale":"xx-XX"}'
check "Apple's recognizer gives no-on-device for a language that it does not know" 'wait_for "speech event: error a1 no-on-device" 10'
stop_app

fi

if runs 4; then
echo
echo "Scenario 4: the account has no access to one private repo"
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
fi

# prepare_mac <name>: a Mac where the setup is done: the zeus command, a workspace with a simulated scripts/zeus.py,
# a claude-eu alias in the shell profile, and a simulated gcloud that signs in unless the state has "gcloud-fail".
prepare_mac() {
  SANDBOX="$WORK/$1/home"
  STATE="$WORK/$1/state"
  mkdir -p "$SANDBOX/.local/bin" "$SANDBOX/Code/zeus/scripts" "$STATE" "$WORK/$1/tools"
  printf 'export PATH="%s:/usr/bin:/bin:/usr/sbin:/sbin"\n' "$SIM_DIR/stubs" >"$SANDBOX/.zprofile"
  # The alias also names a proxy, which the app must drop.
  cat >"$SANDBOX/.zshrc" <<'ZSHRC'
alias claude-eu='CLAUDE_CODE_USE_VERTEX=1 CLOUD_ML_REGION=eu ANTHROPIC_VERTEX_PROJECT_ID=sim-project ANTHROPIC_MODEL=claude-sonnet-5-5 ANTHROPIC_BASE_URL=http://alias.invalid claude'
ZSHRC
  cp "$SANDBOX/.zshrc" "$SANDBOX/.bashrc"
  cat >"$SANDBOX/.local/bin/zeus" <<'ZEUS'
#!/bin/bash
exec "$ZEUS_SIM_REAL_NODE" "$ZEUS_SIM_PAYLOAD/zeus.mjs" "$@"
ZEUS
  cat >"$WORK/$1/tools/gcloud" <<'GCLOUD'
#!/bin/bash
echo "gcloud $*" >>"$ZEUS_SIM_STATE/gcloud-calls"
if [ -f "$ZEUS_SIM_STATE/gcloud-fail" ]; then
  echo "ERROR: (gcloud.auth.application-default.print-access-token) Your default credentials were not found." >&2
  exit 1
fi
echo "ya29.simulated-token-that-the-app-must-never-keep"
GCLOUD
  chmod +x "$SANDBOX/.local/bin/zeus" "$WORK/$1/tools/gcloud"
  cp "$SIM_DIR/payload/handoff-zeus.py" "$SANDBOX/Code/zeus/scripts/zeus.py"
  defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  defaults write "$BUNDLE_ID" setupDone -bool true
  GCLOUD_SIM="$WORK/$1/tools/gcloud"
}

# The n-th start of zeus has this text (zeus-starts.jsonl of the simulated zeus).
start_has() { sed -n "${1}p" "$STATE/zeus-starts.jsonl" 2>/dev/null | grep -q -- "$2"; }
starts() { wc -l <"$STATE/zeus-starts.jsonl" 2>/dev/null | tr -d ' ' || echo 0; }
# The last line of the host bar in the trace has this text.
bar_has() { grep "host bar: " "$TRACE" | tail -1 | grep -qF -- "$1"; }
wait_bar() { # wait_bar <text> [seconds]
  local waited=0
  until bar_has "$1"; do
    sleep 0.5; waited=$((waited + 1))
    if [ "$waited" -ge $(( ${2:-15} * 2 )) ]; then echo "    (timed out waiting for the host bar: $1; last: $(grep "host bar: " "$TRACE" | tail -1))"; return 1; fi
  done
}
# Provider variables that the app inherits and must not pass to an EU session.
INHERITED=(ANTHROPIC_API_KEY=sim-key ANTHROPIC_AUTH_TOKEN=sim-token ANTHROPIC_BASE_URL=http://proxy.invalid
  AWS_BEARER_TOKEN_BEDROCK=sim-bedrock VERTEX_REGION_CLAUDE_OPUS_5_5=us-east5 CLAUDE_CODE_USE_VERTEX=1 CLOUD_ML_REGION=us-east5
  ZEUS_BLIND_MODE=inherited)

if runs 5; then
echo
echo "Scenario 5: Developer Settings, the Claude host switch of a tab, the EU pill, the session cost, blind build mode"
prepare_mac host
echo none >"$STATE/handoff-mode"
launch_app host ZEUS_APP_GCLOUD="$GCLOUD_SIM" ZEUS_APP_TEST_NO_SWITCH_QUESTION=1 "${INHERITED[@]}"
check "a new tab starts on Apolix while the host switch is off" 'wait_count "state: running(" 1 30'
check "the Apolix session has the host name and no Vertex AI switch, as before" \
  'start_has 1 "\"host\":\"apolix\"" && start_has 1 "\"vertex\":null"'
check "an inherited ZEUS_BLIND_MODE never reaches a session" 'start_has 1 "\"blind\":null"'
check "no Google Cloud check runs for Apolix" '[ ! -f "$STATE/gcloud-calls" ]'
wait_count "page loaded: http://127.0.0.1" 1 20 >/dev/null
act test-retina
check "the cost of the chat page reaches the app on connect" 'wait_for "cost: ≈ \$0.42 on apolix shown=false" 10'
check "the Apolix cost is hidden by default, and so are the switch and the pill" 'wait_bar "apolix switch=false pill=false cost=-"'
act dev-settings-show
sleep 1.5
shot 20-developer-settings
act dev-settings-close
act "dev-setting:costApolix=on"
check "the Apolix cost shows at once when its setting turns on" 'wait_bar "apolix switch=false pill=false cost=≈ \$0.42"'
act "dev-setting:switch=on"
check "the host switch shows at once when its setting turns on" 'wait_bar "apolix switch=true pill=false"'
shot_frame 21-apolix-titlebar
act "dev-setting:blind=on"
act switch-host:eu
check "the switch to EU checks the Google Cloud sign-in first" 'wait_for "EU preflight passed" 30'
check "a new session starts on EU in the same tab" 'wait_count "state: running(" 2 30'
check "the Apolix session of the tab stopped with SIGTERM" 'wait_for "replaced by a session on eu" 5 && sleep 1 && [ "$(stops)" = 1 ]'
check "the EU session gets the alias variables and the host name" \
  'start_has 2 "\"host\":\"eu\"" && start_has 2 "\"vertex\":\"1\"" && start_has 2 "\"region\":\"eu\"" && start_has 2 "\"project\":\"sim-project\"" && start_has 2 "\"model\":\"claude-sonnet-5-5\""'
check "the EU session has no API key, token, base URL, Bedrock key, or region override" \
  'start_has 2 "\"apiKey\":null,\"authToken\":null,\"baseUrl\":null,\"bedrock\":null,\"regionOverride\":null"'
check "the EU session turns off nonessential traffic" 'start_has 2 "\"quiet\":\"1\""'
check "blind build mode reaches the new session" 'start_has 2 "\"blind\":\"1\""'
check "the access token is in no trace or output of the app" '! grep -rq "ya29" "$TRACE" "$WORK/host/app.out"'
check "the window count stays one" '[ "$("$BIN/windows" "$APP_PID" | wc -l | tr -d " ")" = 1 ]'
check "the EU tab shows the EU pill and the switch" 'wait_bar "eu switch=true pill=true"'
wait_count "page loaded: http://127.0.0.1" 2 20 >/dev/null
sleep 1
act 'test-cost:{"host":"eu","currency":"EUR","total":1.84,"chat":0.42,"calls":3,"tokens":{"input":10,"cache_read":20,"cache_write_5m":5,"cache_write_1h":0,"output":7},"usd_per_eur":1.11}'
check "a cost report updates the title bar" 'wait_for "cost: ≈ €1.84 on eu shown=true" 10 && wait_bar "eu switch=true pill=true cost=≈ €1.84"'
act 'test-cost:{"host":"apolix","currency":"USD","total":9.99}'
sleep 1
check "a cost report for another host is not shown" '! grep -q "cost: ≈ \$9.99" "$TRACE"'
shot_frame 22-eu-titlebar-dark
act test-light:on
shot_frame 23-eu-titlebar-light
act test-light:off
act "dev-setting:costEU=off"
check "the EU cost hides at once when its setting turns off" 'wait_bar "eu switch=true pill=true cost=-"'
act "dev-setting:costEU=on"
act "dev-setting:blind=off"
act test-cmd-t
check "a new tab starts on the host picked last" 'wait_count "state: running(" 3 30 && start_has 3 "\"host\":\"eu\""'
check "blind build mode off: the new session has no ZEUS_BLIND_MODE" 'start_has 3 "\"blind\":null"'
act switch-host:apolix
check "EU to Apolix without EU work to hand off asks Zeus and skips the handoff step" 'wait_for "handoff: none pending" 20'
check "the Apolix session starts in the new tab" 'wait_count "state: running(" 4 30 && start_has 4 "\"host\":\"apolix\""'
check "the host bar follows the selected tab" 'wait_bar "apolix switch=true pill=false"'
act test-select-first
check "the first tab shows its EU pill again" 'wait_bar "eu switch=true pill=true"'
touch "$STATE/gcloud-fail"
act switch-host:apolix
check "the first tab switches to Apolix" 'wait_count "state: running(" 5 30'
act switch-host:eu
check "without a Google Cloud sign-in the EU start is refused" 'wait_for "EU start refused" 30'
check "the tab shows the failure" 'wait_for "state: failed(" 10'
sleep 2
check "nothing starts on Apolix instead" '[ "$(starts)" = 5 ]'
shot_frame 24-eu-refused
rm -f "$STATE/gcloud-fail"
act "test-retry"
check "Try again starts on EU again after the sign-in" 'wait_count "EU preflight passed" 3 30 && wait_count "state: running(" 6 30 && start_has 6 "\"host\":\"eu\""'
check "the app remembers EU for the next tab" '[ "$(defaults read "$BUNDLE_ID" lastHost 2>/dev/null)" = eu ]'
stop_app
check "every session stopped when the app quit" '[ "$(stops)" = 6 ]'
fi

if runs 6; then
echo
echo "Scenario 6: the EU handoff when a tab switches from EU to Apolix"
prepare_mac handoff
defaults write "$BUNDLE_ID" developerHostSwitch -bool true
defaults write "$BUNDLE_ID" lastHost eu
echo clean >"$STATE/handoff-mode"
launch_app handoff ZEUS_APP_GCLOUD="$GCLOUD_SIM" ZEUS_APP_TEST_NO_SWITCH_QUESTION=1 ZEUS_APP_TEST_NO_OPEN=1 ZEUS_SIM_HANDOFF_DELAY=2.5
check "the tab starts on EU" 'wait_count "state: running(" 1 30 && start_has 1 "\"host\":\"eu\""'
wait_count "page loaded: http://127.0.0.1" 1 20 >/dev/null
act test-retina
sleep 2
act switch-host:apolix
check "the switch asks Zeus which projects need a handoff" 'wait_for "handoff: pending solvias" 20'
check "Zeus runs in the workspace, outside any Claude Code session" 'grep -q "handoff pending --json cwd=.*/handoff/home/Code/zeus workspace=.*/handoff/home/Code/zeus claude=- session=- blind=-" "$STATE/handoff-calls"'
sleep 1.6
shot 30-handoff-step
check "the stages come in live from the progress lines of Zeus" 'wait_for "handoff: stage started: Removing row values" 15'
check "the stages of the scan tick off in order" 'wait_for "handoff: stage 5/5 done: Writing the review page" 15 && grep "handoff: stage [0-9]/5 done" "$TRACE" | sed "s/.*done: //" | tr "\n" "|" | grep -q "^Collecting EU work|Removing row values|Aggregating to structure|Scanning for sensitive values|Writing the review page|$"'
check "the stages take less than 3 s" 'wait_for "handoff: stages shown in" 5 && awk "/handoff: stages shown in/ {exit !(\$6 < 3)}" "$TRACE"'
check "a clean scan offers the release" 'wait_for "handoff: summary projects=1 clean=true findings=0 error=false release=true" 10'
check "the EU session still runs during the handoff" '[ "$(stops)" = 0 ] && [ "$(starts)" = 1 ]'
shot_frame 31-handoff-summary-clean
act test-handoff:review
check "Open review page opens the page of the scan" 'wait_for "handoff: review page 1" 5'
act test-handoff:release
check "Release runs the release with the handoff hash" 'wait_for "handoff: released solvias" 20 && grep -q "handoff release solvias $(printf "a%.0s" {1..64}) --json" "$STATE/handoff-calls"'
check "then the Apolix session starts" 'wait_count "state: running(" 2 30 && start_has 2 "\"host\":\"apolix\""'
check "the release comes before the EU session stops" 'grep -n " handoff release\| stop " "$STATE/sessions" | head -1 | grep -q "handoff release"'

act switch-host:eu
check "the switch back to EU has no handoff step" 'wait_count "state: running(" 3 30 && start_has 3 "\"host\":\"eu\"" && [ "$(grep -c "handoff: pending check" "$TRACE")" = 1 ]'
wait_count "page loaded: http://127.0.0.1" 3 20 >/dev/null
sleep 1.5
echo findings >"$STATE/handoff-mode"
act switch-host:apolix
check "a scan with findings shows them and disables Release" 'wait_for "handoff: summary projects=1 clean=false findings=2 error=false release=false" 20'
check "the blocked review stage shows as failed" 'grep -q "handoff: stage 5/5 failed: Blocked: 2 finding(s) to resolve" "$TRACE"'
shot_frame 32-handoff-summary-findings
act test-handoff:release
check "Release does nothing while the scan has findings" 'wait_for "handoff: release is disabled" 5 && [ "$(grep -c "handoff release" "$STATE/handoff-calls")" = 1 ]'
act test-handoff:stay
check "Stay on EU keeps the EU session" 'wait_for "handoff: outcome stay" 5 && sleep 1 && [ "$(starts)" = 3 ] && [ "$(stops)" = 2 ]'
check "the switch is free again after Stay on EU" 'wait_bar "eu switch=true pill=true"'

echo error >"$STATE/handoff-mode"
act switch-host:apolix
check "a failed build shows the error and no Release" 'wait_for "handoff: summary projects=0 clean=true findings=0 error=true release=false" 20'
sleep 0.5
check "a failed handoff starts nothing by itself" '[ "$(starts)" = 3 ]'
shot_frame 33-handoff-error
act test-handoff:continue
check "Continue without handoff starts Apolix without a release" 'wait_count "state: running(" 4 30 && start_has 4 "\"host\":\"apolix\"" && [ "$(grep -c "handoff release" "$STATE/handoff-calls")" = 1 ]'
act switch-host:eu
check "after a failed handoff, the switch back to EU works" 'wait_count "state: running(" 5 30 && start_has 5 "\"host\":\"eu\""'
wait_count "page loaded: http://127.0.0.1" 5 20 >/dev/null
sleep 1.5
echo pending-error >"$STATE/handoff-mode"
act switch-host:apolix
check "a failed pending check asks the consultant" 'wait_count "handoff: summary projects=0 clean=true findings=0 error=true release=false" 2 20 && grep -q "handoff: pending failed: The project records cannot be read." "$TRACE"'
act test-handoff:stay
check "Stay on EU after a failed check keeps EU" 'wait_count "handoff: outcome stay" 2 5 && sleep 1 && [ "$(starts)" = 5 ]'
echo none >"$STATE/handoff-mode"
act switch-host:apolix
check "with no EU work to hand off, the switch skips the step" 'wait_for "handoff: none pending" 20 && wait_count "state: running(" 6 30 && start_has 6 "\"host\":\"apolix\""'
stop_app
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  printf '\033[32mAll checks passed.\033[0m\n'
else
  printf '\033[31m%s checks failed.\033[0m\n' "$FAILURES"
  exit 1
fi
