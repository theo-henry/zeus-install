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
  echo "of a tab and back, Standard and EU tabs side by side, the EU cost of today, and the restore after an app start"
  eu_sandbox
  local plugin="$SANDBOX/.claude/plugins/cache/zeus-editor/zeus-editor/sim"
  python3 - "$plugin/eu-profile.json" <<'PY'
import json, sys
profile = json.load(open(sys.argv[1]))
profile["isolation"] = False
json.dump(profile, open(sys.argv[1], "w"))
PY
  # An EU vault disk image from earlier tests of EU with isolation: simple EU does not use it.
  BUNDLE="$SANDBOX/Library/Application Support/Zeus/eu-vault.sparsebundle"
  mkdir -p "$BUNDLE"
  # A Touch ID that the app must never ask for: the test answer fails, and the trace names each question.
  launch_app eu-simple ZEUS_APP_TEST_VAULT_AUTH=fail ZEUS_APP_EURO_RATE_URL="file://$STATE/euro-rate.xml"
  need "the app opens a Standard chat" 'wait_for "page loaded: http://127.0.0.1" $PAGE_LOAD_LIMIT && sleep 1'
  check "Standard runs without the read block, though an EU vault disk image is on this Mac" \
    'wait_for "jail: off: simple EU (no isolation)" 10 && ! grep -q "jail: on" "$TRACE" && [ ! -e "$SANDBOX/Library/Application Support/Zeus/jail/standard.sb" ]'
  check "the title bar shows the Standard tab, with no vault" 'mode_bar_has "mode=standard enabled=true access=- cost=- vault=- today=- tabs=standard"'
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
  check "the window has a Standard tab and an EU tab, and the title bar shows the EU tab with the EU cost menu" \
    'mode_bar_has "tabs=standard,eu" && mode_bar_has "mode=eu enabled=true access=- cost=- vault=cost"'
  act test-store
  check "the EU chat page has the EU web data" 'wait_for "web data: eu persistent=.* default=false" 10'

  # The EU cost after a reply, and the EU cost of today in its menu.
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
  check "the title bar shows the EU session cost and the EU cost of today, with no EU data access switch" \
    'wait_for "euro rate: 1.085 of 2026-11-16" 20 && sleep 0.5 && mode_bar_has "access=- cost=EU session cost (estimate): 0.04 EUR vault=cost today=EU cost today (estimate): 0.04 EUR"'
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
}
