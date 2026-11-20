#!/bin/bash
# End-to-end test of Zeus.app and install.sh on a simulated new Mac.
#
# The app runs with HOME set to an empty temporary folder and with simulated tools (xcode-select,
# curl, shasum, conda, gh, npm, claude, zeus) first on PATH, so nothing is downloaded and the real
# home folder, Claude Code, and GitHub login are not used. The test presses the app's buttons through
# its debug test actions (active only with ZEUS_APP_TRACE) and checks the trace.
#
# Usage: app/test/sim/run.sh [--eu | --eu-simple | --vault | --signin] [screenshot-folder]
# With a folder, it saves a screenshot of each app window state there (the app's windows only).
# --eu runs only the EU mode scenario with isolation (the EU vault), --eu-simple only the simple EU scenario (no
# isolation), --vault only the EU vault and Standard read block scenario, and --signin only the Google sign-in step of
# the setup (app/test/run-all.sh runs each part with its own time limit).

# check runs its test, in single quotes, with eval; ShellCheck does not see the variables in it.
# shellcheck disable=SC2016,SC2034
set -euo pipefail

SIM_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$SIM_DIR/../.." && pwd)"
REPO_DIR="$(dirname "$APP_DIR")"
PART=main
if [ "${1:-}" = "--eu" ]; then PART=eu; shift; fi
if [ "${1:-}" = "--eu-simple" ]; then PART=eu-simple; shift; fi
if [ "${1:-}" = "--vault" ]; then PART=vault; shift; fi
if [ "${1:-}" = "--signin" ]; then PART=signin; shift; fi
SHOTS="${1:-}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/zeus-sim.XXXXXX")"
BIN="$WORK/bin"
# Test actions reach only the app copy that this test starts, not another running Zeus app.
export ZEUS_APP_TEST_ID="sim-$$"
# The app copies of this run keep their settings in a domain of their own, not in the settings of the user.
export ZEUS_APP_DEFAULTS_SUITE="io.github.theo-henry.zeus.test-$ZEUS_APP_TEST_ID"
PREFS_DOMAIN="$ZEUS_APP_DEFAULTS_SUITE"
# The app stays behind the windows of other apps and does not take the keyboard (debug builds).
export ZEUS_APP_TEST_BACKGROUND=1
# The app copies download no dictation model (a test that needs one serves its own and sets this to 0).
export ZEUS_APP_NO_MODEL_DOWNLOAD=1
mkdir -p "$BIN"
[ -n "$SHOTS" ] && mkdir -p "$SHOTS"

FAILURES=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
# A failed check shows the end of the app's trace, so that a CI log tells what the app did.
fail() {
  printf '  \033[31mFAIL\033[0m %s\n' "$1"
  FAILURES=$((FAILURES + 1))
  if [ -n "${TRACE:-}" ] && [ -f "$TRACE" ]; then tail -n 25 "$TRACE" | sed 's/^/    | /'; fi
}
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }
# need is a check that the later checks depend on: when it fails, the test stops at once (cleanup runs), so that
# every later check does not wait out its own limit.
need() {
  check "$@"
  if [ "$FAILURES" -gt 0 ]; then echo "  Stopping: the setup of this scenario failed, so the later checks cannot pass."; exit 1; fi
}

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
APP_PID=""

cleanup() {
  [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null || true
  # The vault scenario: its mounted vault and its keychain go before the work folder.
  if declare -F vault_cleanup >/dev/null; then vault_cleanup; fi
  [ -n "${MODEL_SERVER_PID:-}" ] && kill "$MODEL_SERVER_PID" 2>/dev/null || true
  defaults delete "$PREFS_DOMAIN" >/dev/null 2>&1 || true
  # defaults delete can leave the empty settings file of the domain.
  rm -f "$HOME/Library/Preferences/$PREFS_DOMAIN.plist"
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

# Sends a test action to this test's copy of the app only.
act() { "$BIN/act" "@$APP_PID $1"; }

shot() {
  [ -n "$SHOTS" ] || return 0
  sleep 0.8
  local id
  id="$("$BIN/windows" "$APP_PID" | head -1 | awk '{print $1}')"
  # A screenshot is evidence, not a check: a failed capture must not end the test.
  if [ -z "$id" ] || ! screencapture -x -o -l "$id" "$SHOTS/$1.png"; then
    echo "    (screenshot $1 not saved)"
  fi
  return 0
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

# wait_stops <count> [seconds]: waits until that many simulated zeus sessions have stopped.
wait_stops() {
  local waited=0 limit="${2:-20}"
  until [ "$(stops)" -ge "$1" ]; do
    sleep 0.5
    waited=$((waited + 1))
    [ "$waited" -lt $((limit * 2)) ] || return 1
  done
}

# keyboard_has <text>: the selected tab writes where its keyboard is (chat or terminal) and its message box text
# into the trace, and the line has this text.
keyboard_has() {
  local before
  before="$(grep -c "test keyboard: " "$TRACE" || true)"
  act test-keyboard
  wait_count "test keyboard: " $((before + 1)) 10 >/dev/null && grep "test keyboard: " "$TRACE" | tail -1 | grep -qF -- "$1"
}

# pty_got <text>: the simulated zeus of a tab got this text as terminal input. Its terminal is in raw mode, as the
# terminal of zeus: the text comes in at once, without a line end.
pty_got() { grep -q "input [0-9a-f]*$(printf %s "$1" | xxd -p | tr -d '\n')" "$STATE/sessions"; }

# newest_page_loaded [seconds]: waits until the chat page of the newest session has loaded. A test action that runs
# in a chat page (a draft, a project pick, a Zeus Editor link) is lost while the page still loads.
newest_page_loaded() {
  local pid
  pid="$(grep -o "session [0-9]* started" "$TRACE" | tail -1 | awk '{print $2}')"
  [ -n "$pid" ] && wait_for "page loaded: http://127.0.0.1:[0-9]*/chat/$pid" "${1:-20}"
}

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
  mkdir -p "$SANDBOX/Library/Keychains" "$STATE"
  : >"$SANDBOX/Library/Keychains/login.keychain-db"
  # A new Mac: no tools in the home folder, a login keychain, and the simulated tools before the system ones.
  printf 'export PATH="%s:/usr/bin:/bin:/usr/sbin:/sbin"\n' "$SIM_DIR/stubs" >"$SANDBOX/.zprofile"
  defaults delete "$PREFS_DOMAIN" >/dev/null 2>&1 || true
  launch_app "$@"
}

# launch_app <name> [extra env...]: starts the app again in the current simulated home folder.
launch_app() {
  local name="$1"
  shift
  TRACE="$WORK/$name/trace.log"
  mkdir -p "$WORK/$name"
  # ZEUS_APP_TEST_BACKGROUND: the app stays behind the other apps, so the test does not take the screen.
  env HOME="$SANDBOX" SHELL=/bin/zsh ZEUS_APP_TRACE="$TRACE" ZEUS_APP_TEST_BACKGROUND=1 \
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

# shellcheck source=app/test/sim/eu.sh
source "$SIM_DIR/eu.sh"
# shellcheck source=app/test/sim/simple.sh
source "$SIM_DIR/simple.sh"
# shellcheck source=app/test/sim/vault.sh
source "$SIM_DIR/vault.sh"
# shellcheck source=app/test/sim/signin.sh
source "$SIM_DIR/signin.sh"
if [ "$PART" != main ]; then
  case "$PART" in
    eu) eu_scenario ;;
    eu-simple) eu_simple_scenario ;;
    vault) vault_scenario ;;
    signin) signin_scenario ;;
  esac
  echo
  if [ "$FAILURES" -eq 0 ]; then
    printf '\033[32mAll checks passed.\033[0m\n'
    exit 0
  fi
  printf '\033[31m%s checks failed.\033[0m\n' "$FAILURES"
  exit 1
fi

echo
echo "Scenario 1: a new Mac, full setup, chat, close"
start_app new ZEUS_SIM_START_DELAY=2500
need "the setup window opens and checks this Mac" 'wait_for "setup ended: check=true code=0" 30'
todo="$(grep -c 'setup event: state [0-9]* todo' "$TRACE" || true)"
need "the check finds 14 steps to do on a new Mac (got $todo)" '[ "$todo" = 14 ]'
check "the EU plugins step waits for the EU vault (no vault on a new Mac)" 'wait_for "setup event: state 15 always" 5'
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
check "step 6: Node.js installs" 'wait_for "setup event: done 6 " 60'
check "step 7: Claude Code installs" 'wait_for "setup event: done 7 " 30'
check "step 8: content-cli installs" 'wait_for "setup event: done 8 " 30'
check "step 9: the Zeus workspace is cloned" 'wait_for "setup event: done 9 " 30'
check "step 10: the Zeus Editor plugin installs" 'wait_for "setup event: done 10 " 30'
check "step 11: the zeus command installs" 'wait_for "setup event: done 11 " 30'
check "step 12: the Zeus skill plugins install" 'wait_for "setup event: done 12 " 90'
check "step 13: the Claude login starts" 'wait_for "setup event: running 13 " 10'
sleep 1.5
shot 4-claude-login
check "step 13: the Claude login completes" 'wait_for "setup event: done 13 " 30'
check "step 14: the Google Cloud CLI installs in ~/google-cloud-sdk" 'wait_for "setup event: done 14 " 30 && [ -x "$SANDBOX/google-cloud-sdk/bin/gcloud" ]'
check "step 15: without an open EU vault, the EU plugins wait, and the setup writes nothing in ~/.zeus/eu" \
  'wait_for "setup event: skipped 15 Zeus plugins of EU mode (EU vault not open)" 30 && [ ! -e "$SANDBOX/.zeus/eu" ] && [ ! -e "$SANDBOX/Code/zeus-eu" ]'
check "step 16: the installer asks for the Google sign-in of EU mode" 'wait_for "setup event: ask 16 " 20'
shot 5-google-question
act setup-answer-yes
check "step 16: the Google sign-in runs, then the EU project becomes the quota project" \
  'wait_for "setup event: done 16 Google sign-in (EU mode, sim@example.com)" 30 && grep -q "^auth application-default login$" "$STATE/gcloud.log" && grep -q "\"quota_project_id\": \"project-4bf0bacd-fec4-406b-a99\"" "$SANDBOX/.config/gcloud/application_default_credentials.json"'
check "the access check gets the token in files, never on the command line" 'grep -q ":testIamPermissions" "$STATE/curl.log" && ! grep -q "sim-access-token" "$STATE/curl.log"'
check "the setup finishes" 'wait_for "setup ended: check=false code=0" 20'
shot 5-finished
check "the installer wrote only into the simulated home folder" '[ -x "$SANDBOX/.local/bin/zeus" ] && [ -d "$SANDBOX/Code/zeus/.git" ]'
# The EU plugins step with an open vault (the EU vault scenario runs it in a real vault): ZEUS_INSTALL_TEST_EU_VAULT_OPEN.
eu_install() {
  env HOME="$SANDBOX" PATH="$SANDBOX/.local/bin:$SANDBOX/.local/node/bin:$SIM_DIR/stubs:/usr/bin:/bin" ZEUS_SIM_STATE="$STATE" \
    ZEUS_SIM_PAYLOAD="$SIM_DIR/payload" ZEUS_INSTALL_APP=1 ZEUS_INSTALL_TEST_EU_VAULT_OPEN=1 "$@"
}
check "with an open EU vault, step 15 installs the Zeus plugins in the EU Claude Code folder" \
  'eu_install bash -c "ZEUS_INSTALL_SOURCED=1 source \"\$1\"; WORK_DIR=\"\$(mktemp -d)\"; install_eu" _ "$REPO_DIR/install.sh" >"$WORK/eu-install.out" 2>&1 && grep -q "^@@zeus done 15 Zeus plugins of EU mode" "$WORK/eu-install.out" && grep -q "zeus-editor@zeus-editor" "$SANDBOX/.zeus/eu/claude/plugins/installed_plugins.json" && grep -q "celonis-pql@celonis-pql" "$SANDBOX/.zeus/eu/claude/plugins/installed_plugins.json"'
check "the EU plugins are installed apart from the Standard plugins" '[ "$(ls "$STATE" | grep -c "^eu-plugin-")" = 4 ] && [ "$(ls "$STATE" | grep -c "^plugin-")" = 4 ]'
check "EU Claude Code starts without the first-start questions in the shared workspace ~/Code/zeus" \
  'python3 -c "import json,os,sys; c=json.load(open(sys.argv[1])); p=c[\"projects\"][os.path.realpath(sys.argv[2])]; sys.exit(0 if c[\"hasCompletedOnboarding\"] and p[\"hasTrustDialogAccepted\"] and p[\"hasClaudeMdExternalIncludesWarningShown\"] and not p[\"hasClaudeMdExternalIncludesApproved\"] and len(c[\"projects\"])==1 else 1)" "$SANDBOX/.zeus/eu/claude/.claude.json" "$SANDBOX/Code/zeus"'
check "the EU setup changes no shell profile" '! grep -qs "google-cloud-sdk\|zeus-eu\|CLOUDSDK\|CLAUDE_CONFIG_DIR\|\.zeus/eu" "$SANDBOX/.zprofile" "$SANDBOX/.zshrc" "$SANDBOX/.bash_profile" "$SANDBOX/.bashrc"'
check "install.sh --check then finds the EU steps done" \
  '[ "$(eu_install bash "$REPO_DIR/install.sh" --check 2>&1 | grep -c "@@zeus state 1[456] ok")" = 3 ]'
check "install.sh --check without an open vault says that the EU plugins step waits" \
  'env HOME="$SANDBOX" PATH="$SANDBOX/.local/bin:$SANDBOX/.local/node/bin:$SIM_DIR/stubs:/usr/bin:/bin" ZEUS_SIM_STATE="$STATE" ZEUS_SIM_PAYLOAD="$SIM_DIR/payload" ZEUS_INSTALL_APP=1 bash "$REPO_DIR/install.sh" --check >"$WORK/check-locked.out" 2>&1; grep -q "@@zeus state 15 always" "$WORK/check-locked.out"'

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
# Each simulated zeus takes 2.5 s to start (ZEUS_SIM_START_DELAY), and longer on a busy Mac: the checks wait for it.
act test-cmd-t
wait_count "hand-over: at once" 1 30 >/dev/null || true
act test-cmd-t
check "each new tab starts a separate PTY" 'wait_starts 3 && [ "$(grep -c " start " "$STATE/sessions")" = 3 ]'
check "later tabs come in at once, without the globe hand-over" 'wait_count "hand-over: at once" 2 30 && [ "$(grep -c "hand-over: at once" "$TRACE")" = 2 ] && [ "$(grep -c "hand-over: globe moves" "$TRACE")" = 1 ]'
# Tab names: the project of the chat, until the user renames the tab. The app does not keep them.
check "a new tab without a project is named Project" 'grep "tab selected: " "$TRACE" | tail -1 | grep -q " Project$"'
newest_page_loaded >/dev/null && sleep 1 || true
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
# The simulated zeus reads its terminal in raw mode, as zeus does: Enter comes in as \r.
check "xterm input reaches the live PTY" 'grep -q "input 7465726d696e616c2d746573740d" "$STATE/sessions"'
shot 8-terminal-tabs
# A paste goes where the user clicked. The test app is behind the other apps, so each click here is the click that
# only brings the window to the front, which the page does not get: that click must still move the keyboard.
check "Cmd+J gives the keyboard to the terminal" 'keyboard_has " terminal message="'
act "test-pasteboard:Paste line one\nPaste line two"
act test-click-chat
check "a click in the chat box takes the keyboard from the open terminal" 'wait_for "keyboard: .* chat (click)" 10'
act test-paste
check "a multi-line paste goes into the chat box" 'sleep 0.5 && keyboard_has " chat message=\"Paste line one\nPaste line two\""'
check "the paste in the chat box does not reach the terminal" 'sleep 0.5 && ! pty_got "Paste line"'
act test-clear
act "test-pasteboard:One line paste"
act test-paste
check "a one-line paste goes into the chat box" 'sleep 0.5 && keyboard_has " chat message=\"One line paste\""'
act test-clear
act "test-pasteboard:Terminal paste\n"
act test-click-terminal
check "a click in the terminal gives it the keyboard" 'wait_for "keyboard: .* terminal (click)" 10'
act test-paste
check "a paste in the terminal reaches its PTY, not the chat box" 'sleep 1 && pty_got "Terminal paste" && keyboard_has " terminal message=\"\""'
act test-pasteboard-restore
# Another tab, then back: the keyboard goes back to the part that had it, not to the terminal only because it is open.
act test-next-tab
act test-next-tab
check "a tab that shows again gives the keyboard back to its terminal" 'keyboard_has " terminal message="'
act test-click-chat
check "the click in the chat box moves the keyboard back" 'wait_count "keyboard: .* chat (click)" 2 10'
act test-next-tab
act test-next-tab
check "a tab that shows again with its terminal open gives the keyboard back to its chat" 'keyboard_has " chat message="'
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
check "an idle tab closes its PTY" 'wait_stops 3 && [ "$(stops)" = 3 ]'

# A chat that cannot answer the close check (an editor plugin older than the app) must not block the close forever.
touch "$STATE/no-close-state"
act test-cmd-t
check "a tab with an older editor plugin starts" 'wait_starts 4'
rm -f "$STATE/no-close-state"
check "its chat page opens" 'wait_count "state: running(" 4 20 && newest_page_loaded && sleep 1'
act close-chat
sleep 1.5
check "an unanswered close check first waits and keeps the PTY" '! grep -q "close deferred: .* unavailable" "$TRACE" && [ "$(stops)" = 3 ]'
check "an unanswered close check then offers Close anyway" 'wait_for "close deferred: .* unavailable" 10'
shot 10-unavailable-close
sleep 1
check "the tab stays open until the user decides" '[ "$(stops)" = 3 ]'
act test-close-anyway
check "Close anyway closes the tab that cannot answer" 'wait_count "state: ended" 4 10 && [ "$(stops)" = 4 ]'

# Close anyway must also override a busy chat. Its turn is long, so that it is still busy after the screenshot.
touch "$STATE/long-turn"
act test-cmd-t
check "a new tab opens after Close anyway" 'wait_count "state: running(" 5 20 && newest_page_loaded && sleep 1'
rm -f "$STATE/long-turn"
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
wait_starts 6 && newest_page_loaded >/dev/null || true
act test-cmd-t
wait_starts 7 && newest_page_loaded >/dev/null || true
stop_app
check "quit stops every remaining PTY" '[ "$(stops)" = 7 ]'

echo
echo "Scenario 2: a cancelled logout, then a quit and a logout while one tab has a draft and one tab is busy"
defaults write "$PREFS_DOMAIN" setupDone -bool true
launch_app logout
check "the app opens a chat at once after the setup" 'wait_for "page loaded: http://127.0.0.1" 30'
act test-draft
act test-cmd-t
check "a second tab opens" 'wait_count "state: running(" 2 20 && newest_page_loaded && sleep 1'
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
echo "Scenario 2b: the install line closes an open app that has unsent text"
# install-app.sh closes an open app before it replaces it (quit_zeus_app in install.sh). Its quit request must
# reach the app's own quit check, so that a tab with unsent text asks first and nothing is lost.
# The app runs as Zeus.app, as in the Applications folder.
mkdir -p "$WORK/apps"
ditto "$APP" "$WORK/apps/Zeus.app"
DEV_EXE="$EXE"
EXE="$WORK/apps/Zeus.app/Contents/MacOS/Zeus"
launch_app install-quit
check "the app opens a chat" 'wait_for "page loaded: http://127.0.0.1" 30 && sleep 1'
act test-draft
sleep 0.5
(
  export ZEUS_INSTALL_SOURCED=1
  # shellcheck source=install.sh
  source "$REPO_DIR/install.sh"
  quit_zeus_app "$WORK/apps"
) >"$WORK/install-quit/out" 2>&1 &
QUIT_PID=$!
check "the quit of the install line asks about the unsent text, as the app's own quit does" \
  'wait_for "quit deferred: .*composer-draft" 10'
check "the app stays open and the install line waits while the app asks" 'sleep 2 && kill -0 "$APP_PID" && kill -0 "$QUIT_PID"'
check "the unsent text stays in the chat" 'keyboard_has " chat message=\"Test chat turn\""'
kill "$QUIT_PID" 2>/dev/null || true
wait "$QUIT_PID" 2>/dev/null || true
# A logout ends the quit question and the app.
act test-power-off
"$BIN/logout" "$APP_PID"
waited=0
while kill -0 "$APP_PID" 2>/dev/null && [ "$waited" -lt 30 ]; do sleep 0.5; waited=$((waited + 1)); done
check "a logout then ends the app" '! kill -0 "$APP_PID" 2>/dev/null'
kill -0 "$APP_PID" 2>/dev/null && kill "$APP_PID"
APP_PID=""
EXE="$DEV_EXE"

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
check "the chat page can use speech to text, also after it sets window.zeusApp" 'page_has "\"version\":1,\"versions\":[1,2],\"close\":\"function\""'
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
check "the new tab opens" 'wait_count "state: running(" 2 20 && newest_page_loaded && sleep 1'
act 'test-speech-post:{"type":"speech-start","id":"s4","locale":"ja-JP"}'
check "a language without recognition on the Mac gives no-on-device" 'wait_for "speech event: error s4 no-on-device" 10 && sleep 0.5 && ! grep -q "speech event: state s4" "$TRACE"'
act test-open-editor
check "a Zeus Editor page opens" 'wait_for "page loaded: http://127.0.0.1:[0-9]*/editor" 10'
check "the Zeus Editor page can use speech to text" 'page_has "\"version\":1,\"versions\":[1,2]" editor-'
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

echo
echo "Scenario 3b: Whisper dictation with a simulated model (download, fallback, settings, model swap)"
# A model server on this Mac: it sends 64 KiB every 10 ms, and holds a file while "<file>.hold" exists.
MODELS_SRV="$WORK/model-server"
mkdir -p "$MODELS_SRV"
cat >"$WORK/model-server.py" <<'PY'
import http.server, os, sys, time
root = sys.argv[1]
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = os.path.join(root, os.path.basename(self.path.split("?")[0]))
        while os.path.exists(path + ".hold"):
            time.sleep(0.1)
        if not os.path.isfile(path):
            self.send_response(404); self.end_headers(); return
        with open(os.path.join(root, "requests.log"), "a") as log:
            log.write(os.path.basename(path) + "\n")
        size = os.path.getsize(path)
        self.send_response(200)
        self.send_header("Content-Length", str(size))
        self.end_headers()
        with open(path, "rb") as f:
            while chunk := f.read(65536):
                self.wfile.write(chunk)
                time.sleep(0.01)
    def log_message(self, *args):
        pass
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(root, "port"), "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
PY
python3 "$WORK/model-server.py" "$MODELS_SRV" &
MODEL_SERVER_PID=$!
waited=0
until [ -s "$MODELS_SRV/port" ] || [ "$waited" -ge 50 ]; do sleep 0.1; waited=$((waited + 1)); done
MODEL_URL="http://127.0.0.1:$(cat "$MODELS_SRV/port")"
# make_model <file> <first line>: a simulated model of 3 MiB.
make_model() {
  { printf '%s\n' "$2"; head -c 3145728 /dev/zero; } >"$MODELS_SRV/$1"
}
sha_of() { shasum -a 256 "$MODELS_SRV/$1" | awk '{print $1}'; }
size_of() { stat -f %z "$MODELS_SRV/$1"; }
# make_manifest <name> <accurate id> <accurate file> [accurate sha256]: a model list with that accurate model and the fast model.
make_manifest() {
  local sha="${4:-$(sha_of "$3")}"
  cat >"$MODELS_SRV/$1" <<JSON
{"version": 1, "defaultRole": "accurate", "models": [
 {"id": "$2", "role": "accurate", "engine": "whisper", "name": "Accurate", "description": "Simulated multilingual model.",
  "url": "$MODEL_URL/$3", "bytes": $(size_of "$3"), "sha256": "$sha", "multilingual": true, "license": "MIT", "source": "test"},
 {"id": "sim-fast-1", "role": "fast", "engine": "whisper", "name": "Fast", "description": "Simulated English model.",
  "url": "$MODEL_URL/fast-1.bin", "bytes": $(size_of fast-1.bin), "sha256": "$(sha_of fast-1.bin)", "multilingual": false,
  "languages": ["en"], "license": "MIT", "source": "test"}]}
JSON
}
make_model accurate-1.bin "ZEUS-SIMULATED-MODEL multilingual 1"
make_model accurate-2.bin "ZEUS-SIMULATED-MODEL multilingual 2"
make_model accurate-3.bin "NOT A MODEL"
make_model fast-1.bin "ZEUS-SIMULATED-MODEL english-only"
make_manifest v1.json sim-accurate-1 accurate-1.bin
make_manifest v2-bad.json sim-accurate-2 accurate-2.bin 0000000000000000000000000000000000000000000000000000000000000000
make_manifest v2.json sim-accurate-2 accurate-2.bin
make_manifest v3.json sim-accurate-3 accurate-3.bin
MODELS_DIR="$SANDBOX/Library/Application Support/io.github.theo-henry.zeus/whisper-models"
whisper_env() { echo "ZEUS_APP_TEST_SPEECH=whisper ZEUS_APP_NO_MODEL_DOWNLOAD=0 ZEUS_APP_DICTATION_MANIFEST=$MODELS_SRV/$1"; }
# speech_round <id> [seconds]: a start, then a stop after that many seconds, then the final text.
speech_round() {
  act "test-speech-post:{\"type\":\"speech-start\",\"id\":\"$1\",\"locale\":null,\"version\":2}"
  wait_for "speech event: state $1 listening" 10 && sleep "${2:-0.6}"
  act "test-speech-post:{\"type\":\"speech-stop\",\"id\":\"$1\"}"
  wait_for "speech event: state $1 stopped" 10
}

touch "$MODELS_SRV/accurate-1.bin.hold"
# shellcheck disable=SC2046
launch_app whisper $(whisper_env v1.json)
check "the app opens a chat" 'wait_for "page loaded: http://127.0.0.1" 30 && sleep 1'
check "the chat page has speech bridge versions 1 and 2" 'page_has "\"version\":1,\"versions\":[1,2],\"close\":\"function\""'
check "the accurate model downloads in the background after the start" 'wait_for "dictation: download sim-accurate-1 starts (needed)" 10'
act 'test-speech-post:{"type":"speech-status"}'
check "the status says Apple's recognizer while the model is not ready" 'sleep 0.5 && page_has "\"engine\":\"apple\""'
act test-draft
sleep 0.3
act 'test-speech-post:{"type":"speech-start","id":"w0","locale":null}'
check "dictation without a model uses Apple's recognizer" 'wait_for "speech: start w0 locale=default engine=apple" 10 && wait_for "speech event: state w0 listening engine=apple" 10'
act 'test-speech-post:{"type":"speech-stop","id":"w0"}'
check "Apple's recognizer gives its final text" 'wait_for "speech event: state w0 stopped" 10 && page_has "\"text\":\"Test chat turnHello Zeus.\""'
rm -f "$MODELS_SRV/accurate-1.bin.hold"
check "the download shows its progress, is checked, and the model loads" 'wait_for "dictation: download sim-accurate-1 checked" 20 && wait_for "dictation: loaded sim-accurate-1" 10 && page_has "accurate:sim-accurate-1:downloading" && page_has "accurate:sim-accurate-1:ready"'
check "the status says Whisper when the model is loaded" 'sleep 0.5 && page_has "\"engine\":\"whisper\""'
check "the model is in the models folder of the app, with installed.json" '[ -f "$MODELS_DIR/sim-accurate-1.bin" ] && grep -q "sim-accurate-1" "$MODELS_DIR/installed.json"'
act test-clear
speech_round w1 0.8
check "Whisper listens, sends the audio level, then processing, then the final text after the stop" \
  'page_has "\"state w1 listening\",\"level w1 \"" && page_has "\"state w1 processing\",\"final w1 Hello Zeus.\",\"state w1 stopped\"" && page_has "\"text\":\"Hello Zeus.\""'
check "the trace has the time from the stop to the text" 'grep -q "speech: final w1 engine=whisper stop-to-text=[0-9]* ms" "$TRACE"'
act test-clear
act 'test-speech-post:{"type":"speech-start","id":"v1","locale":null}'
check "a version 1 page (no version in its start) still gets the words while the user speaks" \
  'wait_for "speech: start v1 locale=default engine=hybrid bridge=1" 10 && wait_for "speech event: partial v1 chars=10" 10'
act 'test-speech-post:{"type":"speech-stop","id":"v1"}'
check "then it gets the Whisper text through the version 1 events, before its 4 s deadline" \
  'wait_for "speech event: state v1 stopped" 10 && grep -q "speech: final v1 engine=whisper stop-to-text=[0-9]* ms" "$TRACE" && [ "$(grep "speech: final v1 " "$TRACE" | sed "s/.*stop-to-text=\([0-9]*\) ms/\1/")" -lt 4000 ] && page_has "\"partial v1 Hello Zeus\",\"final v1 Hello Zeus.\",\"state v1 stopped\""'
act 'test-speech-post:{"type":"speech-settings-set","customWords":[" Celonis ","Apolix","celonis",""]}'
check "the custom words are saved for both chats, cleaned, and counted in tokens" \
  'sleep 0.5 && page_has "\"customWords\":[\"Celonis\",\"Apolix\"]" && page_has "\"included\":2" && defaults read "$PREFS_DOMAIN" dictationCustomWords | grep -q Apolix'
act test-clear
speech_round w2
check "the custom words go to the model as its prompt" 'page_has "\"text\":\"Hello Zeus. [Celonis, Apolix.]\""'
act 'test-speech-post:{"type":"speech-settings-set","language":"fr"}'
act test-clear
speech_round w3
check "a fixed language goes to the model" 'page_has "Hello Zeus. (fr) [Celonis, Apolix.]"'
act 'test-speech-post:{"type":"speech-settings-set","language":"xx"}'
check "an unknown language is refused with an error, and the setting stays" 'sleep 0.5 && page_has "unknown language" && page_has "\"language\":\"fr\""'
act 'test-speech-post:{"type":"speech-start","id":"w4","locale":null,"version":2}'
wait_for "speech event: state w4 listening" 10 >/dev/null
# The stop and the next start go in one post, so the start comes while Whisper processes, also under load.
act 'test-speech-post:[{"type":"speech-stop","id":"w4"},{"type":"speech-start","id":"w5","locale":null,"version":2}]'
check "a start while Whisper processes is busy" 'wait_for "speech event: state w4 processing" 10 && sleep 0.3 && page_has "error w5 busy"'
check "the processing recording still gives its text" 'wait_for "speech event: final w4 " 10'
act 'test-speech-post:{"type":"speech-start","id":"w6","locale":null,"version":2}'
wait_for "speech event: state w6 listening" 10 >/dev/null
act 'test-speech-post:{"type":"speech-stop","id":"w6"}'
wait_for "speech event: state w6 processing" 10 >/dev/null
act 'test-speech-post:{"type":"speech-cancel","id":"w6"}'
check "a cancel while Whisper processes gives stopped and no text" 'wait_for "speech: cancel w6 (page)" 10 && sleep 1 && page_has "state w6 stopped" && ! grep -q "speech event: final w6" "$TRACE"'
act 'test-speech-post:{"type":"speech-settings-set","model":"fast"}'
check "the Fast model downloads when the user picks it, and loads" 'wait_for "dictation: download sim-fast-1 starts (needed)" 10 && wait_for "dictation: loaded sim-fast-1" 20'
act test-clear
speech_round w7
check "the English-only model decodes English, also with French in the settings" 'page_has "\"text\":\"Hello Zeus. (en) [Celonis, Apolix.]\"" && page_has "\"effectiveLanguage\":\"en\""'
act test-clear
act 'test-speech-post:{"type":"speech-start","id":"v3","locale":"de-DE"}'
wait_for "speech event: state v3 listening" 10 >/dev/null
act 'test-speech-post:{"type":"speech-stop","id":"v3"}'
check "a version 1 page in a language that the English-only model does not decode gets only Apple's text" \
  'wait_for "speech event: state v3 stopped" 10 && grep -q "speech: final v3 engine=apple" "$TRACE"'
act 'test-speech-post:{"type":"speech-settings-set","model":"accurate","language":"auto"}'
check "back to the Accurate model: it loads again from this Mac" 'wait_count "dictation: loaded sim-accurate-1" 2 10 && [ "$(grep -c "^accurate-1.bin$" "$MODELS_SRV/requests.log")" = 1 ]'
touch "$MODELS_SRV/accurate-1.bin.hold"
act 'test-speech-post:{"type":"speech-model-download","model":"accurate"}'
check "a re-download of the model on this Mac fetches it again" 'wait_count "dictation: download sim-accurate-1 starts (requested)" 1 10'
act test-clear
speech_round w9
check "dictation keeps working with the current model during the re-download" 'page_has "\"final w9 Hello Zeus." && grep -q "speech: final w9 engine=whisper" "$TRACE"'
rm -f "$MODELS_SRV/accurate-1.bin.hold"
check "the re-download is checked again, replaces the file, and the runtime loads the new copy" \
  'wait_count "dictation: download sim-accurate-1 checked" 2 20 && wait_count "dictation: loaded sim-accurate-1" 3 10 && [ "$(grep -c "^accurate-1.bin$" "$MODELS_SRV/requests.log")" = 2 ] && [ ! -e "$MODELS_DIR/sim-accurate-1.bin.download" ]'
# The dictated text is a draft; without it, the quit asks nothing.
act test-clear
sleep 0.3
stop_app
# shellcheck disable=SC2046
launch_app whisper-limit $(whisper_env v1.json) ZEUS_APP_TEST_RECORDING_LIMIT=2 ZEUS_APP_TEST_V1_DEADLINE=0.2
check "the app loads the model on this Mac at start, without a download" 'wait_for "dictation: loaded sim-accurate-1" 60 && ! grep -q "download sim-accurate-1 starts" "$TRACE"'
check "the chat opens" 'wait_for "page loaded: http://127.0.0.1" 30 && sleep 1'
act 'test-speech-post:{"type":"speech-start","id":"v2","locale":null}'
wait_for "speech event: state v2 listening" 10 >/dev/null
sleep 0.5
act 'test-speech-post:{"type":"speech-stop","id":"v2"}'
check "when Whisper is not ready in time, a version 1 page gets the text of Apple's recognizer" \
  'wait_for "speech: v1 Whisper text not ready in 0.2 s" 10 && wait_for "speech: final v2 engine=apple" 10 && wait_for "speech event: state v2 stopped" 10'
act test-clear
sleep 0.3
act 'test-speech-post:{"type":"speech-start","id":"w8","locale":null,"version":2}'
check "the recording limit stops the recording and gives the text" 'wait_for "speech: whisper recording 2\.[0-9] s (10-minute limit)" 10 && wait_for "speech event: final w8 " 10 && page_has "\"state w8 processing\""'
act test-clear
sleep 0.3
stop_app
# shellcheck disable=SC2046
launch_app whisper-bad $(whisper_env v2-bad.json)
check "a new model with a wrong checksum fails and Zeus tries again later" 'wait_for "dictation: download sim-accurate-2 failed: The download does not have the expected SHA-256 checksum.; retry in 30 s" 20'
check "the old model stays in use" 'wait_for "dictation: loaded sim-accurate-1" 20 && [ -f "$MODELS_DIR/sim-accurate-1.bin" ] && [ ! -e "$MODELS_DIR/sim-accurate-2.bin" ]'
# A quit while the chat page still loads is deferred: the page can not answer the close check yet.
newest_page_loaded 60 >/dev/null || true
stop_app
# shellcheck disable=SC2046
launch_app whisper-swap $(whisper_env v2.json)
check "after an app update with a new model list, the new model downloads, loads, and replaces the old one" \
  'wait_for "dictation: loaded sim-accurate-2" 30 && wait_for "dictation: accurate model is now sim-accurate-2, was sim-accurate-1" 5'
check "the old model file is deleted, and the new one is kept" 'sleep 0.5 && [ ! -e "$MODELS_DIR/sim-accurate-1.bin" ] && [ -f "$MODELS_DIR/sim-accurate-2.bin" ] && [ -f "$MODELS_DIR/sim-fast-1.bin" ]'
stop_app
# shellcheck disable=SC2046
launch_app whisper-noload $(whisper_env v3.json)
check "a new model that does not load is removed, and the old model stays in use" \
  'wait_for "dictation: model sim-accurate-3 does not load" 30 && wait_for "dictation: loaded sim-accurate-2" 10 && [ ! -e "$MODELS_DIR/sim-accurate-3.bin" ] && [ -f "$MODELS_DIR/sim-accurate-2.bin" ]'
stop_app
kill "$MODEL_SERVER_PID" 2>/dev/null || true
rm -rf "$MODELS_DIR"
defaults delete "$PREFS_DOMAIN" dictationModel >/dev/null 2>&1 || true
defaults delete "$PREFS_DOMAIN" dictationLanguage >/dev/null 2>&1 || true
defaults delete "$PREFS_DOMAIN" dictationCustomWords >/dev/null 2>&1 || true

echo
echo "Scenario 4: keyboard shortcuts from the Zeus settings file"
SETTINGS="$SANDBOX/Library/Application Support/Zeus/settings.json"
mkdir -p "$(dirname "$SETTINGS")"
# Changed shortcuts only; a reserved shortcut, a shortcut without Cmd or Ctrl, and a shortcut of another action give the default.
cat >"$SETTINGS" <<'JSON'
{"version": 1, "shortcuts": {"app.newTab": "Shift+Cmd+K", "app.toggleTerminal": "Cmd+Q", "app.closeTab": "Shift+K",
 "app.newChat": "Ctrl+Tab", "chat.send": "Cmd+Enter"}, "theme": "dark"}
JSON
DEFAULT_SHORTCUTS="app.newChat=Cmd+N app.closeTab=Cmd+W app.nextTab=Ctrl+Tab app.prevTab=Ctrl+Shift+Tab app.toggleTerminal=Cmd+J"
launch_app shortcuts
check "the app opens a chat" 'wait_for "page loaded: http://127.0.0.1" 30 && sleep 1'
check "the app reads the changed shortcuts at launch" 'grep -q "shortcuts: app.newTab=Shift+Cmd+K $DEFAULT_SHORTCUTS (launch)" "$TRACE"'
check "a reserved shortcut, a shortcut without Cmd or Ctrl, and a shortcut of two actions give the default" \
  'grep -q "app.toggleTerminal Cmd+Q is reserved" "$TRACE" && grep -q "app.closeTab Shift+K needs Cmd or Ctrl" "$TRACE" && grep -q "app.newChat Ctrl+Tab is used twice" "$TRACE"'
# menu_has <text>: the app writes the shortcuts of the app menu items into the trace, and the line has this text.
menu_has() {
  local before
  before="$(grep -c "menu shortcuts: " "$TRACE" || true)"
  act test-menu-shortcuts
  wait_count "menu shortcuts: " $((before + 1)) 10 >/dev/null && grep "menu shortcuts: " "$TRACE" | tail -1 | grep -qF -- "$1"
}
# shortcuts_page_has <text>: the chat page of the selected tab writes its window.zeusApp into the trace, and it has this text.
shortcuts_page_has() {
  local before
  before="$(grep -c "shortcuts page: " "$TRACE" || true)"
  act test-shortcuts-page
  wait_count "shortcuts page: " $((before + 1)) 10 >/dev/null && grep "shortcuts page: " "$TRACE" | tail -1 | grep -qF -- "$1"
}
check "the menu shows the shortcuts of the settings file" 'menu_has "app.newTab=Shift+Cmd+K $DEFAULT_SHORTCUTS"'
check "the chat page knows the app actions, also after it sets window.zeusApp" \
  'shortcuts_page_has "{\"shortcuts\":{\"appActions\":[\"app.newTab\",\"app.newChat\",\"app.closeTab\",\"app.nextTab\",\"app.prevTab\",\"app.toggleTerminal\"],\"version\":1},\"close\":\"function\""'
starts="$(grep -c " start " "$STATE/sessions")"
act test-key:Cmd+T
check "the old shortcut Cmd+T does not open a tab" 'sleep 3 && [ "$(grep -c " start " "$STATE/sessions")" = "$starts" ]'
act test-key:Shift+Cmd+K
check "the new shortcut Shift+Cmd+K opens a tab" 'wait_starts $((starts + 1)) && wait_count "state: running(" 2 20 && newest_page_loaded && sleep 1'
act test-key:Cmd+J
check "Cmd+J still shows the terminal" 'wait_for "terminal visible: .* true" 10'
act test-key:Ctrl+Shift+Tab
check "Control-Shift-Tab still shows the previous tab" 'wait_count "tab selected: " 3 10'
# A browser saves the settings: a temp file and a rename. The app applies the change at once.
printf '%s\n' '{"version": 1, "shortcuts": {"app.newTab": "Alt+Cmd+T", "app.nextTab": "Ctrl+]"}}' >"$SETTINGS.tmp"
mv "$SETTINGS.tmp" "$SETTINGS"
check "a saved settings file applies at once" 'wait_for "shortcuts: app.newTab=Alt+Cmd+T app.newChat=Cmd+N app.closeTab=Cmd+W app.nextTab=Ctrl+] .* (file)" 10'
# The menu shows a symbol key as the character of this Mac's keyboard at that place ("]" can show as "´").
check "the menu shows the new shortcuts" 'menu_has "app.newTab=Alt+Cmd+T app.newChat=Cmd+N app.closeTab=Cmd+W app.nextTab=Ctrl+" && ! menu_has "app.nextTab=Ctrl+Tab"'
act test-key:Alt+Cmd+T
check "the changed shortcut opens a tab" 'wait_starts $((starts + 2)) && newest_page_loaded'
selected="$(grep -c "tab selected: " "$TRACE")"
act "test-key:Ctrl+]"
check "the changed next-tab shortcut shows the next tab" 'wait_count "tab selected: " $((selected + 1)) 10'
# An editor that writes the file in place.
printf '%s\n' '{"version": 1, "shortcuts": {"app.newTab": "Ctrl+Alt+T"}}' >"$SETTINGS"
check "a file written in place applies at once" 'wait_for "shortcuts: app.newTab=Ctrl+Alt+T $DEFAULT_SHORTCUTS (file)" 10'
act test-settings-changed
check "the settings-changed message of a page reads the file again" 'wait_for "shortcuts: unchanged (page)" 10'
printf '{not json' >"$SETTINGS"
check "a damaged settings file gives the defaults without a crash" 'wait_for "settings file is not valid JSON" 10 && wait_for "shortcuts: app.newTab=Cmd+T $DEFAULT_SHORTCUTS (file)" 10 && kill -0 "$APP_PID"'
act test-key:Cmd+T
check "Cmd+T opens a tab again" 'wait_starts $((starts + 3)) && newest_page_loaded'
# A chain of collisions: newTab keeps Cmd+N only until newChat goes back to its default Cmd+N.
printf '%s\n' '{"version": 1, "shortcuts": {"app.newTab": "Cmd+N", "app.newChat": "Cmd+J"}}' >"$SETTINGS"
check "a chain of collisions gives each action its own shortcut" \
  'wait_for "app.newChat Cmd+J is used twice" 10 && wait_for "app.newTab Cmd+N is used twice" 10 && wait_for "shortcuts: unchanged (file)" 10'
# Zeus Editor windows match a symbol key with Shift by its place, as the chat window does (";" with Shift types ":").
printf '%s\n' '{"version": 1, "shortcuts": {"app.newTab": "Shift+Cmd+;"}}' >"$SETTINGS"
check "a symbol key shortcut applies" 'wait_for "shortcuts: app.newTab=Shift+Cmd+; $DEFAULT_SHORTCUTS (file)" 10'
act test-open-editor
check "a Zeus Editor page opens" 'wait_for "page loaded: http://127.0.0.1:[0-9]*/editor" 10'
# Settings… at once after the new tab opens, while the tab still shows its loading screen: no chat page has loaded yet.
hand_overs="$(grep -c "hand-over: " "$TRACE" || true)"
act "test-editor-key:Shift+Cmd+;"
act test-close-editor
act test-settings
check "the shortcut opens a tab from a Zeus Editor window" 'wait_starts $((starts + 4))'
new_tab="$(grep "session [0-9]* started" "$TRACE" | tail -1 | awk '{print $3}')"
check "Settings… while the new tab loads waits for its chat page" 'wait_for "settings: waiting for the chat page of $new_tab" 10'
check "Settings… then opens the settings of the chat page in front, once" \
  'wait_for "page loaded: http://127.0.0.1:[0-9]*/chat/$new_tab" 20 && shortcuts_page_has "\"settings\":1"'
rm -f "$SETTINGS"
# Settings… goes to the chat page of the tab in front, so the new tab shows its chat page first.
wait_count "hand-over: " $((hand_overs + 1)) 30 >/dev/null
act test-settings
check "Settings… opens the settings of a loaded chat page at once" 'wait_count "settings opened" 2 10 && shortcuts_page_has "\"settings\":2"'
shot 13-shortcuts
stop_app

echo
echo "Scenario 5: the account has no access to one private repo"
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
echo "Scenario 5b: an EU step fails, and the Standard setup still completes"
# EU mode is for some users only: a failed EU step is a warning. The app tells what EU mode misses when the user switches.
start_app eu-step-fails ZEUS_SIM_GCLOUD_DOWNLOAD_FAIL=1
check "the setup window checks this Mac" 'wait_for "setup ended: check=true code=0" 30'
act setup-install
wait_for "setup event: ask 2 " 40 >/dev/null && act setup-answer-yes
wait_for "setup event: running 4 " 40 >/dev/null && sleep 1 && act setup-enter
check "step 14 fails: the Google Cloud CLI download fails" 'wait_for "setup event: failed 14 The download of google-cloud-cli-" 120 && [ ! -e "$SANDBOX/google-cloud-sdk" ]'
check "the later EU steps still run" 'wait_for "setup event: skipped 15 " 30'
check "step 16 fails without the Google Cloud CLI, and asks nothing" 'wait_for "setup event: failed 16 The Google Cloud CLI is not installed" 30 && ! grep -q "setup event: ask 16 " "$TRACE"'
check "the setup completes without an error" 'wait_for "setup ended: check=false code=0" 20 && [ "$(grep -c "setup event: failed " "$TRACE")" = 2 ]'
shot 7b-eu-step-failed
act setup-start
check "Standard mode starts" 'wait_for "page loaded: http://127.0.0.1" 30 && sleep 1'
act test-mode:eu
check "EU mode names the missing Google Cloud CLI" 'wait_for "mode: EU setup missing: .*the Google Cloud CLI" 10'
act test-alert:1
check "in Terminal use, a failed EU step is a warning, and the steps after it run" \
  'out="$(env HOME="$SANDBOX" PATH="$SANDBOX/.local/bin:$SANDBOX/.local/node/bin:$SIM_DIR/stubs:/usr/bin:/bin" ZEUS_SIM_STATE="$STATE" ZEUS_SIM_PAYLOAD="$SIM_DIR/payload" ZEUS_SIM_INSTALLER="$REPO_DIR/install.sh" ZEUS_SIM_GCLOUD_DOWNLOAD_FAIL=1 bash -c "ZEUS_INSTALL_SOURCED=1 source \"\$1\"; WORK_DIR=\"\$(mktemp -d)\"; install_eu; echo after-eu; printf \"%s\\n\" \"\${SUMMARY[@]}\"" _ "$REPO_DIR/install.sh" 2>&1)" && printf "%s" "$out" | grep -q "^after-eu$" && printf "%s" "$out" | grep -q "Warning:.*google-cloud-cli" && printf "%s" "$out" | grep -q "^warning   Google Cloud CLI (not set up; EU mode only)$" && ! printf "%s" "$out" | grep -q "Stopped:"'
blocked="$WORK/eu-config-blocked"
mkdir -p "$blocked/.zeus"
: >"$blocked/.zeus/eu"
check "an EU step that fails without its own message (an EU config folder that can not be made) is reported failed, and the setup goes on" \
  'out="$(env HOME="$blocked" PATH="$SIM_DIR/stubs:/usr/bin:/bin" ZEUS_INSTALL_APP=1 ZEUS_INSTALL_TEST_EU_VAULT_OPEN=1 bash -c "ZEUS_INSTALL_SOURCED=1 source \"\$1\"; WORK_DIR=\"\$(mktemp -d)\"; eu_step install_eu_plugins \"Zeus plugins of EU mode\"; echo after-eu; printf \"%s\\n\" \"\${SUMMARY[@]}\"" _ "$REPO_DIR/install.sh" 2>&1)" && [ "$(printf "%s\n" "$out" | grep -c "^@@zeus failed ")" = 1 ] && printf "%s" "$out" | grep -q "^@@zeus failed 15 Zeus plugins of EU mode could not be set up" && printf "%s" "$out" | grep -q "^after-eu$" && printf "%s" "$out" | grep -q "^warning   Zeus plugins of EU mode (not set up; EU mode only)$"'
stop_app

echo
if [ "$FAILURES" -eq 0 ]; then
  printf '\033[32mAll checks passed.\033[0m\n'
else
  printf '\033[31m%s checks failed.\033[0m\n' "$FAILURES"
  exit 1
fi
