# Simple EU scenario of the app on a simulated Mac (app/test/sim/run.sh --eu-simple). Sourced by run.sh: it uses its
# helpers (act, check, need, wait_for, launch_app, stop_app, ...) and eu_sandbox and mode_bar_has of eu.sh.
# The EU launch profile of Zeus Editor says `"isolation": false` (simple EU): an EU tab is a Standard tab with the EU model
# account (zeus --eu), so the app makes, opens, and mounts no EU vault, asks for no Touch ID, and runs Standard without
# the read block, also on a Mac that has an EU vault from before. The per-tab switch, the EU badge, and the EU cost stay.
# check runs its test, in single quotes, with eval; ShellCheck does not see the variables in it.
# shellcheck disable=SC2016,SC2034,SC2154

eu_simple_scenario() {
  echo
  echo "Scenario simple EU: an EU tab like a Standard tab with the EU account, no EU vault and no read block, the switch"
  echo "of a tab and back, Standard and EU tabs side by side, the EU cost, the old EU folders kept, and the restore after"
  echo "an app start"
  eu_sandbox
  local plugin="$SANDBOX/.claude/plugins/cache/zeus-editor/zeus-editor/sim"
  python3 - "$plugin/eu-profile.json" <<'PY'
import json, sys
profile = json.load(open(sys.argv[1]))
profile["isolation"] = False
json.dump(profile, open(sys.argv[1], "w"))
PY
  # EU folders from before the shared workspace (the old EU Claude Code folder in a plain ~/.zeus/eu, and ~/Code/zeus-eu of
  # eu_sandbox): simple EU does not use them, and the app never removes them.
  mkdir -p "$SANDBOX/.zeus/eu/claude"
  printf '{"old": true}\n' >"$SANDBOX/.zeus/eu/claude/settings.json"
  check "in simple EU, install.sh --check finds the EU plugins step done: EU uses the plugins of Standard" \
    'env HOME="$SANDBOX" PATH="$SANDBOX/.local/bin:$SANDBOX/.local/node/bin:$SIM_DIR/stubs:/usr/bin:/bin" ZEUS_SIM_STATE="$STATE" ZEUS_INSTALL_APP=1 bash "$REPO_DIR/install.sh" --check >"$WORK/eu/simple-check.out" 2>&1; grep -q "@@zeus state 15 ok" "$WORK/eu/simple-check.out"'
  check "in simple EU, the EU plugins step installs nothing and asks for no vault" \
    'env HOME="$SANDBOX" PATH="$SIM_DIR/stubs:/usr/bin:/bin" ZEUS_SIM_STATE="$STATE" ZEUS_INSTALL_APP=1 bash -c "ZEUS_INSTALL_SOURCED=1 source \"\$1\"; WORK_DIR=\"\$(mktemp -d)\"; install_eu_plugins" _ "$REPO_DIR/install.sh" >"$WORK/eu/simple-plugins.out" 2>&1 && grep -q "^@@zeus skipped 15 Zeus plugins of EU mode (not needed)$" "$WORK/eu/simple-plugins.out" && ! grep -qi "vault" "$WORK/eu/simple-plugins.out" && [ "$(cat "$SANDBOX/.zeus/eu/claude/settings.json")" = "{\"old\": true}" ]'
  # An EU vault disk image from earlier tests of EU with isolation: simple EU does not use it.
  BUNDLE="$SANDBOX/Library/Application Support/Zeus/eu-vault.sparsebundle"
  mkdir -p "$BUNDLE"
  # A Touch ID that the app must never ask for: the test answer fails, and the trace names each question.
  launch_app eu-simple ZEUS_APP_TEST_VAULT_AUTH=fail ZEUS_APP_EURO_RATE_URL="file://$STATE/euro-rate.xml"
  need "the app opens a Standard chat" 'wait_for "page loaded: http://127.0.0.1" $PAGE_LOAD_LIMIT && sleep 1'
  check "Standard runs without the read block, though an EU vault disk image is on this Mac" \
    'wait_for "jail: off: simple EU (no isolation)" 10 && ! grep -q "jail: on" "$TRACE" && [ ! -e "$SANDBOX/Library/Application Support/Zeus/jail/standard.sb" ]'
  check "the title bar shows the Standard tab, with no vault" 'mode_bar_has "mode=standard enabled=true access=- cost=- vault=- tabs=standard"'
  shot simple-1-standard

  # New EU Chat: an EU tab starts at once, as a Standard tab does, with no vault and no Touch ID.
  act test-new-eu-chat
  need "New EU Chat starts an EU tab" 'wait_for "session [0-9]* started (eu)" 20'
  eu_pid="$(last_pid)"
  check "zeus runs with --eu --no-open in ~/Code/zeus, the workspace of Standard" \
    'wait_file_has "\"pid\":$eu_pid,\"args\":\[\"--eu\",\"--no-open\"\],\"cwd\":\"[^\"]*/Code/zeus\"" "$STATE/zeus-starts" 20'
  check "the EU chat page loads" 'wait_for "page loaded: http://127.0.0.1:[0-9]*/chat/$eu_pid" $PAGE_LOAD_LIMIT && sleep 1'
  check "no Touch ID, no vault, and no vault question" \
    '! grep -q "vault: \|mode: eu vault" "$TRACE" && ! mount | grep -qF "$SANDBOX/.zeus/eu" && [ ! -e "$SANDBOX/.zeus/eu/.zeus-vault" ]'
  check "the EU tab is not refused for a missing vault" '! grep -q " no-vault" "$STATE/sessions"'
  check "the EU status line step of the installer does not run (EU uses the Claude Code folder of Standard)" '! grep -q "eu status line: " "$TRACE"'
  check "the window has a Standard tab and an EU tab, and the title bar shows the EU tab with no vault" \
    'mode_bar_has "tabs=standard,eu" && mode_bar_has "mode=eu enabled=true access=- cost=- vault=-"'
  act test-store
  check "the EU chat page has the EU web data" 'wait_for "web data: eu persistent=.* default=false" 10'

  # The EU cost after a reply.
  cat >"$STATE/euro-rate.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01" xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref">
<Cube><Cube time='2026-11-16'><Cube currency='USD' rate='1.0850'/></Cube></Cube>
</gesmes:Envelope>
XML
  act test-draft
  sleep 0.3
  act test-send
  check "the EU page sends the session cost after the reply" 'wait_for "eu cost: $eu_pid session=0.045255" 20'
  check "the title bar shows the EU session cost, with no EU data access switch and no vault" \
    'wait_for "euro rate: 1.085 of 2026-11-16" 20 && sleep 0.5 && mode_bar_has "access=- cost=EU session cost (estimate): 0.04 EUR vault=-"'
  shot simple-2-eu-tab

  # The same project in both tabs at the same time.
  act test-pick-project:acme
  check "the EU tab works on acme, with no EU data access switch" 'wait_for "tab name: acme project=acme" 10 && sleep 0.5 && mode_bar_has "mode=eu enabled=true access=- "'
  act test-select-tab:0
  sleep 0.5
  act test-pick-project:acme
  check "the Standard tab works on acme too, and both sessions run" \
    'wait_count "tab name: acme project=acme" 2 10 && ! grep -q "^$eu_pid stop" "$STATE/sessions" && mode_bar_has "mode=standard enabled=true"'

  # The EU tab switches to Standard and back: one question each, no handover choice, and no Touch ID.
  act test-select-tab:1
  sleep 0.5
  act test-mode:standard
  check "the switch of the EU tab to Standard asks first" 'wait_for "tab mode: $eu_pid switch to standard asked" 10'
  shot simple-3-switch-question
  act test-alert:0
  need "the tab starts a new Standard chat" 'wait_for "tab mode: $eu_pid switch now standard" 20'
  back_pid="$(last_pid)"
  check "the EU chat of the tab ends, and the new chat is Standard without the read block" \
    'wait_file_has "^$eu_pid stop" "$STATE/sessions" 20 && wait_file_has "\"pid\":$back_pid,\"args\":\[\"--no-open\"\]" "$STATE/zeus-starts" 20 && ! grep -q "jail: on" "$TRACE"'
  check "the question offered no handover" '! grep -q "handover: " "$TRACE"'
  newest_page_loaded "$PAGE_LOAD_LIMIT" >/dev/null || true
  sleep 1
  act test-mode:eu
  check "the switch back to EU asks first" 'wait_for "tab mode: $back_pid switch to eu asked" 10'
  act test-alert:0
  need "the tab is EU again, with no Touch ID" 'wait_for "tab mode: $back_pid switch now eu" 20 && ! grep -q "vault: " "$TRACE"'
  eu2_pid="$(last_pid)"
  check "the window has a Standard tab and an EU tab again" 'newest_page_loaded $PAGE_LOAD_LIMIT && sleep 1 && mode_bar_has "tabs=standard,eu"'

  # Restore after an app start: both tabs open again in their modes, with no Touch ID.
  standard_pid="$(grep -o "session [0-9]* started (standard)" "$TRACE" | head -1 | awk '{print $2}')"
  standard_chat="$(grep "^$standard_pid session " "$STATE/sessions" | tail -1 | awk '{print $3}')"
  eu_chat="$(grep "^$eu2_pid session " "$STATE/sessions" | tail -1 | awk '{print $3}')"
  act test-keep-tabs-and-quit
  check "the app keeps both tabs and quits" 'wait_for "restore: kept 2 tabs" 20'
  local waited=0
  while kill -0 "$APP_PID" 2>/dev/null && [ "$waited" -lt 40 ]; do sleep 0.5; waited=$((waited + 1)); done
  check "the EU tab record is in the app folder, as the Standard record" \
    '[ -f "$SANDBOX/Library/Application Support/Zeus/restore-eu.json" ] && grep -q "$eu_chat" "$SANDBOX/Library/Application Support/Zeus/restore-eu.json" && [ ! -e "$SANDBOX/.zeus/eu/editor/app" ]'
  launch_app eu-simple-restore ZEUS_APP_TEST_VAULT_AUTH=fail ZEUS_APP_TEST_RESTORE=1
  check "both tabs open again, each in its own mode and order, with no Touch ID" \
    'wait_for "restore: 1 EU tabs ready" 30 && wait_for "restore: 2 tabs in 1 windows" 20 && wait_count "state: running(" 2 $PAGE_LOAD_LIMIT && mode_bar_has "tabs=standard,eu" && ! grep -q "vault: " "$TRACE"'
  check "each chat resumes in its own mode" \
    'wait_file_has " resume $eu_chat" "$STATE/sessions" 30 && wait_file_has " resume $standard_chat" "$STATE/sessions" 30'
  check "the restore records are removed" '[ ! -e "$SANDBOX/Library/Application Support/Zeus/restore.json" ] && [ ! -e "$SANDBOX/Library/Application Support/Zeus/restore-eu.json" ]'
  newest_page_loaded "$PAGE_LOAD_LIMIT" >/dev/null || true
  sleep 1
  shot simple-4-restored
  stop_app
  check "the app made no vault: the disk image from before is untouched, and nothing is mounted" \
    '[ -d "$BUNDLE" ] && [ -z "$(ls -A "$BUNDLE")" ] && ! mount | grep -qF "$SANDBOX/.zeus/eu"'
  check "the old EU folders stay: ~/Code/zeus-eu and the plain ~/.zeus/eu" \
    '[ -f "$SANDBOX/Code/zeus-eu/clients/acme/out/rows.csv" ] && [ -d "$SANDBOX/Code/zeus-eu/.git" ] && [ "$(cat "$SANDBOX/.zeus/eu/claude/settings.json")" = "{\"old\": true}" ]'
  switch_before_hand_over
  not_safe_while_starting
}

# The first chat of an app run with a chat page that does not say "chat-ready" hands over 2.5 s after its page loaded.
# The test makes that wait 10 s, so that the switch ends before it also on a slow Mac. A mode switch within the wait
# gives the tab a new session; the timer of the old page must not take the loading screen of the new chat while its
# page still loads (the tab lifecycle, app/Sources/Zeus/TabLifecycle.swift).
switch_before_hand_over() {
  echo
  echo "A mode switch before the hand-over of the first chat: the timer of the old page does not act on the new chat"
  rm -f "$STATE/slow-page"
  touch "$STATE/no-chat-ready"
  launch_app eu-simple-switch ZEUS_APP_TEST_VAULT_AUTH=fail ZEUS_APP_TEST_PAGE_LOAD_WAIT=10
  need "the first chat page loads, and it does not say chat-ready" 'wait_for "page loaded: http://127.0.0.1:[0-9]*/chat/" $PAGE_LOAD_LIMIT'
  local old_pid new_pid target=eu
  old_pid="$(last_pid)"
  # The app opens the mode of the tab that the user used last: the switch goes to the other mode.
  grep -q "session $old_pid started (eu)" "$TRACE" && target=standard
  # The page of the new chat comes 20 s after it is asked for: the timer of the old page fires while it loads.
  echo 20000 >"$STATE/slow-page"
  act "test-mode:$target"
  wait_for "tab mode: $old_pid switch to $target asked" 5 >/dev/null || true
  act test-alert:0
  need "the tab switches to $target" 'wait_for "tab mode: $old_pid switch now $target" 20'
  new_pid="$(last_pid)"
  check "the page-load timer of the old page fires after the switch, and the tab ignores it" \
    'wait_for "tab callback ignored: [0-9]* page-load timer" 15'
  check "no hand-over before the page of the new chat has loaded" \
    'wait_for "page loaded: http://127.0.0.1:[0-9]*/chat/$new_pid" 40 && ! sed -n "/tab mode: $old_pid switch now $target/,/page loaded: http:\/\/127.0.0.1:[0-9]*\/chat\/$new_pid/p" "$TRACE" | grep -q "hand-over: "'
  # The new chat is still the first chat of the run: it hands over 10 s after its page loaded.
  check "the new chat then hands over from its own page" 'wait_for "hand-over: " 20'
  rm -f "$STATE/no-chat-ready" "$STATE/slow-page"
  stop_app
}

# A tab where Zeus starts (no chat page yet) or resumes its kept session after an update gives one answer to each reader:
# "starting", the reason that the chat page itself gives while Claude Code starts (TabLifecycle.Activity). Cmd+W shows the
# close banner with Close anyway, the mode switch asks first, the update waits, and the quit question lists the tab.
not_safe_while_starting() {
  echo
  echo "A tab where Zeus starts or resumes is not safe to close: Cmd+W, the mode switch, the update, and the quit"
  rm -f "$STATE/slow-start" "$STATE/slow-resume" "$STATE/no-chat-ready" "$STATE/slow-page"
  launch_app eu-simple-starting ZEUS_APP_TEST_VAULT_AUTH=fail
  need "the app opens a chat" 'wait_for "page loaded: http://127.0.0.1:[0-9]*/chat/" $PAGE_LOAD_LIMIT && sleep 1'
  # The zeus of the next tab prints its chat URL only after 120 s.
  echo 120000 >"$STATE/slow-start"
  act test-cmd-t
  need "a second tab starts" 'wait_count "session [0-9]* started" 2 20'
  starting_readers "starting" "$(last_pid)" simple-5-starting
  rm -f "$STATE/slow-start"

  launch_app eu-simple-keep ZEUS_APP_TEST_VAULT_AUTH=fail
  need "the app opens a chat" 'wait_for "page loaded: http://127.0.0.1:[0-9]*/chat/" $PAGE_LOAD_LIMIT && sleep 1'
  act test-keep-tabs-and-quit
  need "the app keeps its tab and quits" 'wait_for "restore: kept 1 tabs" 20'
  local waited=0
  while kill -0 "$APP_PID" 2>/dev/null && [ "$waited" -lt 40 ]; do sleep 0.5; waited=$((waited + 1)); done
  # The kept session resumes only after 120 s.
  echo 120000 >"$STATE/slow-resume"
  launch_app eu-simple-resuming ZEUS_APP_TEST_VAULT_AUTH=fail ZEUS_APP_TEST_RESTORE=1
  need "the kept tab opens again and resumes its session" 'wait_for "tab phase: [0-9]* starting -> resuming" 30'
  starting_readers "resuming" "$(last_pid)" simple-6-resuming
  rm -f "$STATE/slow-resume"
}

# starting_readers <phase> <pid of its session> <screenshot prefix>: the selected tab is in that phase.
starting_readers() {
  local phase="$1" pid="$2" shots="$3" target=eu
  grep -Eq "session $pid started \((restore, )?eu\)" "$TRACE" && target=standard
  act test-busy-tabs
  check "$phase: the update waits for the tab" 'wait_for "busy tabs: 1" 10'
  act close-chat
  check "$phase: Cmd+W shows that Zeus is starting, with Close anyway" 'wait_for "close deferred: $pid starting" 10'
  shot "$shots-close"
  check "$phase: the tab stays open" 'sleep 1 && ! grep -q "^$pid stop" "$STATE/sessions"'
  act test-cancel-close
  check "$phase: Cancel close keeps the tab" 'wait_for "close cancelled: $pid" 10'
  act "test-mode:$target"
  wait_for "tab mode: $pid switch to $target asked" 10 >/dev/null || true
  act test-alert:0
  check "$phase: the mode switch asks first" 'wait_for "tab mode: switch deferred: starting" 10'
  shot "$shots-switch"
  act test-alert:1
  check "$phase: Cancel keeps the tab in its mode" 'wait_for "tab mode: $pid switch cancelled" 10 && ! grep -q "^$pid stop" "$STATE/sessions"'
  act quit
  check "$phase: the quit question lists the tab" 'wait_for "quit deferred: .*starting" 10'
  shot "$shots-quit"
  # A logout (macOS first warns of the power off, then sends the quit event) ends the quit question and the app.
  act test-power-off
  "$BIN/logout" "$APP_PID"
  local waited=0
  while kill -0 "$APP_PID" 2>/dev/null && [ "$waited" -lt 40 ]; do sleep 0.5; waited=$((waited + 1)); done
  check "$phase: a logout then ends the app" '! kill -0 "$APP_PID" 2>/dev/null'
  kill -0 "$APP_PID" 2>/dev/null && kill "$APP_PID"
  APP_PID=""
  return 0
}
