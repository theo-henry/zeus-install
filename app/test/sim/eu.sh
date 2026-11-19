# EU mode scenario of the app on a simulated Mac (app/test/sim/run.sh --eu). Sourced by run.sh: it uses its helpers
# (act, check, need, wait_for, launch_app, shot, ...) and its simulated tools. No Google or Anthropic service is called:
# `zeus --eu` is the simulated zeus (payload/zeus.mjs), gcloud is payload/gcloud, and the zeus handoff commands of the
# Standard workspace are payload/zeus_handoff.py, which keeps the app contract of the real ones (zeus references/eu-mode.md).
# check runs its test, in single quotes, with eval; ShellCheck does not see the variables in it.
# shellcheck disable=SC2016,SC2034,SC2154

# A Mac after the Zeus setup, with EU mode set up as install.sh does it (steps 14 to 16, which Scenario 1 tests):
# the Google Cloud CLI, the EU workspace, and the Zeus Editor plugin in the EU Claude Code folder. No sign-in yet.
eu_sandbox() {
  SANDBOX="$WORK/eu/home"
  STATE="$WORK/eu/state"
  mkdir -p "$SANDBOX" "$STATE"
  printf 'export PATH="%s:/usr/bin:/bin:/usr/sbin:/sbin"\n' "$SIM_DIR/stubs" >"$SANDBOX/.zprofile"
  mkdir -p "$SANDBOX/.local/bin" "$SANDBOX/.local/node/bin"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$REAL_NODE" >"$SANDBOX/.local/node/bin/node"
  (
    export ZEUS_INSTALL_SOURCED=1
    # shellcheck source=install.sh
    source "$REPO_DIR/install.sh"
    write_zeus_shim
  ) >"$SANDBOX/.local/bin/zeus"
  chmod +x "$SANDBOX/.local/bin/zeus" "$SANDBOX/.local/node/bin/node"
  local plugin="$SANDBOX/.claude/plugins/cache/zeus-editor/zeus-editor/sim"
  mkdir -p "$plugin/dist"
  cp "$SIM_DIR/payload/zeus.mjs" "$plugin/dist/zeus.mjs"
  cp "$SIM_DIR/payload/eu-profile.json" "$plugin/eu-profile.json"
  mkdir -p "$SANDBOX/google-cloud-sdk/bin"
  cp "$SIM_DIR/payload/gcloud" "$SANDBOX/google-cloud-sdk/bin/gcloud"
  # The Standard workspace and the EU workspace (a second clone), each with the project acme.
  local workspace
  for workspace in zeus zeus-eu; do
    mkdir -p "$SANDBOX/Code/$workspace/clients/acme"
    git -C "$SANDBOX/Code/$workspace" init -q
    printf '{"project_id": "acme"}\n' >"$SANDBOX/Code/$workspace/clients/acme/project.json"
  done
  local eu="$SANDBOX/Code/zeus-eu"
  mkdir -p "$SANDBOX/Code/zeus/scripts" "$eu/scripts" "$eu/clients/acme/work/view" "$eu/clients/acme/out"
  cp "$SIM_DIR/payload/zeus_handoff.py" "$SANDBOX/Code/zeus/scripts/zeus.py"
  # EU Claude can write the EU workspace: a changed zeus.py there, and modules next to it and in the working folder,
  # would report a clean scan. The app must never run or import them; each one leaves a mark when it runs.
  local planted
  for planted in "$eu/scripts/zeus.py" "$eu/scripts/json.py" "$eu/json.py"; do
    cat >"$planted" <<PY
import sys
open("$STATE/eu-code-ran", "a").write(__file__ + "\\n")
print('{"projects": [], "findings": [], "clean": true}')
sys.exit(0)
PY
  done
  printf '{"title": "ACME orders", "kpi": "PU_COUNT(orders)"}\n' >"$eu/clients/acme/work/view/spec.json"
  printf 'id,customer\n1,ACME\n' >"$eu/clients/acme/out/rows.csv"
  # The summary that EU Zeus writes when the app asks for it (payload/zeus.mjs, the control "send").
  cat >"$STATE/eu-summary.md" <<'MD'
# Handover summary

## Goal

Build the order KPI View for acme.

## Decisions

- Count orders per month. Contact: ana@example.com

## Findings

None

## Open items

- None

## Artifacts

- work/view/spec.json
- out/rows.csv

## Zeus feedback

None
MD
  printf 'acme\n' >"$STATE/eu-summary-project"
  defaults delete "$PREFS_DOMAIN" >/dev/null 2>&1 || true
  defaults write "$PREFS_DOMAIN" setupDone -bool true
}

# mode_bar_has <text>: the title bar of the last tab's window writes its state into the trace, and it has this text.
mode_bar_has() {
  local before
  before="$(grep -c "mode bar: " "$TRACE" || true)"
  act test-mode-bar
  wait_count "mode bar: " $((before + 1)) 10 >/dev/null && grep "mode bar: " "$TRACE" | tail -1 | grep -qF -- "$1"
}

# pages_answer: selects each tab of the chat window in turn and waits until its chat page answers a page check
# (test-keyboard runs a script in the page and writes the answer into the trace). The selection ends on the tab that
# was selected. A mode switch then asks only pages that have answered, also the pages of hidden tabs on a busy Mac.
pages_answer() {
  local before tabs i
  before="$(grep -c "mode bar: " "$TRACE" || true)"
  act test-mode-bar
  wait_count "mode bar: " $((before + 1)) 10 >/dev/null || return 1
  tabs="$(grep "mode bar: " "$TRACE" | tail -1 | sed "s/.* tabs=//" | tr , "\n" | grep -c .)"
  for ((i = 0; i < tabs; i++)); do
    before="$(grep -c "test keyboard: " "$TRACE" || true)"
    act test-next-tab
    act test-keyboard
    wait_count "test keyboard: " $((before + 1)) 30 >/dev/null || return 1
  done
}

# handover_has <text>: the handover window writes its state into the trace, and it has this text.
handover_has() {
  local before
  before="$(grep -c "handover state: " "$TRACE" || true)"
  act test-handover-state
  wait_count "handover state: " $((before + 1)) 10 >/dev/null && grep "handover state: " "$TRACE" | tail -1 | grep -qF -- "$1"
}

# wait_handover <text> [seconds]
wait_handover() {
  local waited=0 limit="${2:-20}"
  until handover_has "$1"; do
    sleep 1
    waited=$((waited + 1))
    [ "$waited" -lt "$limit" ] || return 1
  done
}

# wait_file_has <text> <file> [seconds]
wait_file_has() {
  local waited=0 limit="${3:-20}"
  until grep -q -- "$1" "$2" 2>/dev/null; do
    sleep 0.5
    waited=$((waited + 1))
    [ "$waited" -lt $((limit * 2)) ] || return 1
  done
}

# last_pid: the pid of the newest started session.
last_pid() { grep -o "session [0-9]* started" "$TRACE" | tail -1 | awk '{print $2}'; }

# PAGE_LOAD_LIMIT: the seconds that a new chat page may take to load after an app start, a mode switch, or a new
# chat. Other test workers can load the Mac, and the page load of a new session then can take more than a minute.
PAGE_LOAD_LIMIT=90

eu_scenario() {
  echo
  echo "Scenario EU: the Standard | EU switch, the EU start check and sign-in, the cost, the handover, and the way back"
  eu_sandbox
  # The EU Claude Code folder has no Zeus plugins yet: EU mode needs the setup first.
  launch_app eu ZEUS_APP_EURO_RATE_URL="file://$STATE/euro-rate.xml"
  need "the app opens a Standard chat" 'wait_for "page loaded: http://127.0.0.1" $PAGE_LOAD_LIMIT && sleep 1'
  check "the app starts in Standard mode" 'grep -q "launched: .* mode=standard" "$TRACE" && mode_bar_has "mode=standard enabled=true pill=false access=- cost=-"'
  check "zeus runs without --eu in ~/Code/zeus" 'grep -q "\"args\":\[\"--no-open\"\],\"cwd\":\"[^\"]*/Code/zeus\"" "$STATE/zeus-starts"'
  act test-store
  check "Standard pages use the default web data" 'wait_for "web data: standard persistent=true default=true" 10'
  shot eu-1-standard
  act test-mode:eu
  check "EU mode asks for its setup when the EU plugins are missing" 'wait_for "mode: EU setup missing: the Zeus plugins of EU mode" 10'
  shot eu-2-setup-needed
  act test-alert:1
  check "Cancel keeps Standard mode" 'sleep 1 && mode_bar_has "mode=standard enabled=true" && ! grep -q " start eu" "$STATE/sessions"'
  mkdir -p "$SANDBOX/.zeus/eu/claude/plugins"
  printf '{"version": 2, "plugins": {"zeus-editor@zeus-editor": [{"scope": "user"}]}}\n' >"$SANDBOX/.zeus/eu/claude/plugins/installed_plugins.json"

  # Standard to EU: one question (with the clipboard note the first time), then every Standard session stops before
  # EU starts, and no claude-eu alias or shell function takes part (the simulated Mac has none).
  standard_pid="$(last_pid)"
  standard_session="$(grep "^$standard_pid session " "$STATE/sessions" | tail -1 | awk '{print $3}')"
  act test-draft
  sleep 0.3
  act test-mode:eu
  check "the switch to EU asks first" 'wait_for "mode: switch to eu asked" 10'
  shot eu-3-switch-question
  act test-alert:0
  check "a tab with unsent text asks once more" 'wait_for "mode: switch deferred: composer-draft" 10'
  act test-alert:0
  need "EU mode starts" 'wait_for "mode: now eu" 30 && wait_for "session [0-9]* started (eu)" 10'
  eu_pid="$(last_pid)"
  wait_file_has "\"pid\":$eu_pid," "$STATE/zeus-starts" 10 || true
  check "the Standard session stopped before the EU session started" \
    'awk -v s="$standard_pid" -v e="$eu_pid" "\$1==s && \$2==\"stop\" {stopped=NR} \$1==e && \$2==\"start\" {started=NR} END {exit !(stopped && started && stopped < started)}" "$STATE/sessions"'
  check "zeus runs with --eu --no-open in the EU workspace" 'grep -q "\"pid\":$eu_pid,\"args\":\[\"--eu\",\"--no-open\"\],\"cwd\":\"[^\"]*/Code/zeus-eu\"" "$STATE/zeus-starts"'
  check "the EU chat page loads" 'wait_for "page loaded: http://127.0.0.1:[0-9]*/chat/$eu_pid" $PAGE_LOAD_LIMIT && sleep 1'
  check "the Standard tab is kept for the way back" 'grep -q "$standard_session" "$SANDBOX/Library/Application Support/Zeus/tabs-standard.json"'
  check "the title bar shows EU with the green pill" 'mode_bar_has "mode=eu enabled=true pill=true access=- cost=-"'
  act test-store
  check "EU pages have their own web data" 'wait_for "web data: eu persistent=.* default=false" 10'
  shot eu-4-eu-chat

  # The session cost after each reply (the bridge message cost:<JSON>), in USD.
  act test-draft
  sleep 0.3
  act test-send
  check "the EU page sends the session cost after the reply" 'wait_for "eu cost: $eu_pid session=0.045255 chat=0.045220 calls=2 unpriced=0" 20'
  check "without the ECB rate of today, the cost shows in USD with a note" 'mode_bar_has "cost=EU session cost (estimate): 0.05 USD (no euro rate)" && wait_for "euro rate: not loaded" 10'
  check "Standard mode never loaded the euro rate" '[ "$(grep -c "euro rate: " "$TRACE")" = 1 ]'
  cat >"$STATE/euro-rate.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01" xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref">
<Cube><Cube time='2026-11-16'><Cube currency='JPY' rate='163.20'/><Cube currency='USD' rate='1.0850'/></Cube></Cube>
</gesmes:Envelope>
XML
  act test-euro-rate-reset
  act test-draft
  sleep 0.3
  act test-send
  check "with the ECB rate of today, the title bar shows the EU session cost in euros" 'wait_for "euro rate: 1.085 of 2026-11-16" 20 && mode_bar_has "pill=true access=- cost=EU session cost (estimate): 0.08 EUR"'
  check "the rate is kept for the day" 'grep -q "\"loadedOn\":\"$(date +%Y-%m-%d)\"" "$SANDBOX/Library/Application Support/Zeus/euro-rate.json"'
  shot eu-5-cost
  # A Vertex error of the chat (the bridge message eu-error:<JSON>) shows the words of the EU start check.
  act 'test-post:"eu-error:{\"status\":429,\"model\":\"claude-sonnet-5-5\"}"'
  check "a Vertex 429 shows the no-capacity message" 'wait_for "eu error shown: The EU project has no capacity for claude-sonnet-5-5 now" 10'
  shot eu-6-vertex-error
  act test-alert:0
  # A Standard page that sends a cost shows nothing: covered by the mode check of ChatTab (only EU tabs exist now).

  # The EU start check fails: the tab says why and how to fix it, and Standard never starts in its place.
  printf 'signin\n' >"$STATE/eu-preflight"
  act new-chat
  check "an EU start without a Google sign-in stops with its message" 'wait_for "eu start failed: [0-9]* exit=3 sign-in=true You are not signed in to Google Cloud for EU mode." 20'
  sleep 1
  shot eu-7-sign-in-needed
  # A failed login: the tab gives the exit code and points to the gcloud output.
  : >"$STATE/eu-sign-in-fails"
  act 'test-post:"eu-sign-in"'
  check "a failed Google login gives its exit code" 'wait_for "eu sign-in: ended code=1" 20 && wait_for "eu sign-in: note The Google sign-in did not complete (exit code 1). See the terminal below (Cmd+J)." 10'
  rm -f "$STATE/eu-sign-in-fails"
  # An account without the Service Usage Consumer role: gcloud refuses the quota project, and the tab gives the
  # access words of the EU start check in place of the gcloud error.
  : >"$STATE/eu-quota-denied"
  act 'test-post:"eu-sign-in"'
  check "a quota project refused for a missing permission gives the access message" 'wait_count "eu sign-in: ended code=1" 2 20 && wait_for "eu sign-in: note Your Google account has no access to the EU project of Zeus. Ask the Zeus maintainer for the Vertex AI User and Service Usage Consumer roles.$" 10'
  shot eu-7b-sign-in-no-access
  check "the refused sign-in does not start EU mode again" '[ "$(grep -c "session [0-9]* started (eu)" "$TRACE")" = 2 ]'
  rm -f "$STATE/eu-quota-denied"
  act 'test-post:"eu-sign-in"'
  check "Sign in to Google Cloud runs the sign-in in the terminal panel" 'wait_for "eu sign-in: started" 10 && wait_for "terminal visible: .* true" 10'
  check "the sign-in sets the EU project as the quota project" 'wait_for "eu sign-in: ended code=0" 20 && grep -q "^auth application-default login$" "$STATE/gcloud.log" && grep -q "^auth application-default set-quota-project project-4bf0bacd-fec4-406b-a99$" "$STATE/gcloud.log"'
  check "after the sign-in, EU mode starts again" 'wait_count "session [0-9]* started (eu)" 3 20 && wait_count "state: running(" 3 20'
  printf '403\n' >"$STATE/eu-preflight"
  act new-chat
  check "an account without access gets the access message, without the sign-in button" 'wait_for "eu start failed: [0-9]* exit=3 sign-in=false Your Google account sim@example.com has no access" 20'
  shot eu-8-no-access
  rm -f "$STATE/eu-preflight"
  act 'test-post:"retry"'
  check "Try again starts EU mode again" 'wait_count "session [0-9]* started (eu)" 5 20 && wait_count "state: running(" 4 20'
  check "no Standard session started in EU mode" '[ "$(grep -c " start standard" "$STATE/sessions")" = 1 ]'

  # The handover: EU Zeus writes the summary on request; the app builds, scans, and masks it in its own folder, outside
  # Claude; the user decides each finding group (Keep or Mask) and releases it.
  # The user picks the project acme in the chat page. It is not yet the Claude session's project, so the request names it.
  # The pick needs the project menu of the new EU chat page, so the test waits until that page has loaded.
  need "the EU chat page of Try again loads" 'newest_page_loaded $PAGE_LOAD_LIMIT && sleep 1'
  act test-pick-project:acme
  need "a project picked in the EU chat names the tab" 'wait_for "tab name: acme project=acme" 10'

  # EU data access: off until the user turns it on with the switch in the title bar; the app runs Zeus outside Claude.
  check "the title bar shows EU data access of the tab's project, off" 'wait_for "eu access: acme read off" 20 && mode_bar_has "access=off "'
  act test-eu-access:acme=on
  sleep 0.5
  act test-alert:1
  check "turning EU data access on asks first" 'wait_for "test alert: Turn on EU data access for acme? -> 1" 10 && wait_for "eu access: acme on cancelled" 10'
  check "Cancel keeps it off" '[ ! -e "$SANDBOX/.zeus/eu/data-access/acme.json" ] && mode_bar_has "access=off "'
  act test-eu-access:acme=on
  sleep 0.5
  act test-alert:0
  check "Turn On runs eu-access on outside Claude, and the title bar shows on" \
    'wait_for "eu access: acme on$" 10 && python3 -c "import json,sys; r=json.load(open(sys.argv[1])); sys.exit(0 if r[\"enabled\"] is True else 1)" "$SANDBOX/.zeus/eu/data-access/acme.json" && mode_bar_has "access=on "'
  check "eu-access ran the Standard copy of zeus.py with no Claude session" \
    'grep "\"eu-access\", \"acme\", \"on\"" "$STATE/handoff.log" | grep -q "\"CLAUDECODE\": null" && grep "\"eu-access\", \"acme\", \"on\"" "$STATE/handoff.log" | grep -q "/Code/zeus/scripts/zeus.py"'
  act test-eu-access:acme=off
  check "turning it off needs no question" 'wait_for "eu access: acme off$" 10 && mode_bar_has "access=off "'
  shot eu-9-data-access

  # Nothing to hand over: the window says why.
  mv "$SANDBOX/Code/zeus-eu/clients/acme/work" "$SANDBOX/Code/zeus-eu/clients/acme/work.off"
  # Switch to Standard from EU offers the handover first; Hand Over First opens the handover window.
  act test-mode:standard
  check "the switch to Standard offers the handover first" 'wait_for "mode: switch to standard asked" 10'
  shot eu-10-switch-back
  act test-alert:0
  need "Hand Over First opens the handover window" 'wait_for "handover: window opened" 10 && wait_handover "phase=list" 20'
  check "with no EU work, the window says that there is nothing to hand over, and why" 'handover_has "projects=[] " && handover_has "nothing=No EU project has work to hand over: acme has no changed files"'
  mv "$SANDBOX/Code/zeus-eu/clients/acme/work.off" "$SANDBOX/Code/zeus-eu/clients/acme/work"
  act test-handover-refresh
  need "the project with EU work shows" 'wait_handover "phase=list projects=[\"acme:false\"]" 20'
  shot eu-11-handover-list
  act test-handover-ask
  check "the app asks EU Zeus in a chat to write the summary of the tab's project" 'wait_for "handover: summary asked in [0-9]* sent=true" 10 && grep -q " send The_user_hands_over_the_EU_work_of_the_project_acme_to" "$STATE/sessions"'
  check "the saved summary shows up by itself" 'wait_handover "projects=[\"acme:true\"]" 20 && grep -q "A handover summary is ready to review." "$TRACE"'
  act test-handover-open:acme
  check "the app builds and scans the handover" 'wait_handover "phase=review" 20'
  app_root="$SANDBOX/Library/Application Support/Zeus/handover"
  id="$(ls "$SANDBOX/Code/zeus-eu/clients/acme/handoff" | head -1)"
  check "the app builds the handover in its own folder, owner only, and nothing in the EU workspace" \
    '[ -f "$app_root/acme/$id/manifest.json" ] && [ -f "$app_root/acme/$id/files/work/view/spec.json" ] && [ "$(stat -f %Lp "$app_root")" = 700 ] && [ "$(ls "$SANDBOX/Code/zeus-eu/clients/acme/handoff/$id")" = summary.md ]'
  check "build, scan, and pending run with the app folder, never a folder in the EU workspace" \
    'grep -q "\"handoff\", \"build\", \"acme\", \"--dir\", \"[^\"]*/Library/Application Support/Zeus/handover/acme/$id\", \"--json\"" "$STATE/handoff.log" && grep -q "\"handoff\", \"scan\", \"acme\", \"$id\", \"--dir\", \"[^\"]*/Library/Application Support/Zeus/handover/acme/$id\"" "$STATE/handoff.log"'
  check "only the listed files that may cross are in it" 'handover_has "files=[\"summary.md\", \"files/work/view/spec.json\"]"'
  check "the findings show as groups, undecided, and Release is off" 'handover_has "groups=[\"email:open\", \"known-value:open\"]" && handover_has "open=2 masked=0 release=false"'
  act test-handover-value:ana@example.com
  check "the sheet shows the real value of a finding, read from the app's copy" 'wait_for "handover value shown: true" 10'
  check "no value goes into a log (only the test's own action names one)" '! grep -v "test action: " "$TRACE" | grep -q "ana@example.com\|ACME"'
  check "the handoff commands run the Standard copy of zeus.py, pointed at the EU workspace, and no code of the EU workspace" \
    'python3 -c "import json,os,sys; home=os.path.realpath(sys.argv[2]); calls=[json.loads(x) for x in open(sys.argv[1])]; sys.exit(0 if calls and all(c[\"script\"]==home+\"/Code/zeus/scripts/zeus.py\" and not any(p==home+\"/Code/zeus-eu\" or p.startswith(home+\"/Code/zeus-eu/\") for p in c[\"path\"]) for c in calls) else 1)" "$STATE/handoff.log" "$SANDBOX" && [ ! -e "$STATE/eu-code-ran" ]'
  check "the handoff commands run outside Claude, with the EU profile" \
    'grep -q "\"args\": \[\"--workspace\", \"[^\"]*/Code/zeus-eu\", \"handoff\", \"build\", \"acme\"" "$STATE/handoff.log" && ! grep -q "\"ZEUS_MODE\": \"eu\"\|\"CLAUDE_CODE_USE_VERTEX\": \"1\"\|\"CLAUDE_CONFIG_DIR\": \"/" "$STATE/handoff.log" && grep -q "\"ZEUS_EU_PROFILE\": \"[^\"]*/zeus-editor/sim/eu-profile.json\"" "$STATE/handoff.log"'
  shot eu-12-handover-review

  # A forged scan answer for another project (a decoy folder) is refused, and nothing is released.
  printf '0decoy\n' >"$STATE/scan-project"
  act test-handover-rebuild
  check "a scan answer for another project is refused" 'wait_handover "phase=failed" 20 && grep -q "zeus handoff scan: exit 3" "$TRACE" && [ ! -e "$SANDBOX/Code/zeus/clients/acme/handoff" ]'
  rm -f "$STATE/scan-project"
  act test-handover-retry
  check "Back to the Review scans again with the user's choices" 'wait_handover "phase=review" 20 && handover_has "groups=[\"email:open\", \"known-value:open\"]"'

  act test-handover-keep-all
  check "an e-mail address can not be kept, so the release stays off" 'sleep 0.5 && handover_has "groups=[\"email:open\", \"known-value:keep\"]" && handover_has "release=false"'
  act 'test-handover-summary:# Handover summary\n\n## Goal\n\nBuild the order KPI View for acme.\n\n## Decisions\n\n- Count orders per month.\n\n## Findings\n\n- Orders 4711 and 9876 are test records.\n\n## Open items\n\n- None\n\n## Artifacts\n\n- work/view/spec.json\n\n## Zeus feedback\n\nNone\n'
  check "an edited summary is scanned again, and a Keep stays for the same value" 'wait_handover "groups=[\"number:open\", \"number:open\", \"known-value:keep\"]" 20'
  act test-handover-remove:files/work/view/spec.json
  check "a removed file needs no choice" 'sleep 0.5 && handover_has "files=[\"summary.md\", \"files/work/view/spec.json-\"]" && handover_has "groups=[\"number:open\", \"number:open\"]"'
  act test-handover-include:files/work/view/spec.json
  act test-handover-mask-all
  check "Mask All masks every open group, and Release is possible" 'sleep 0.5 && handover_has "groups=[\"number:mask\", \"number:mask\", \"known-value:keep\"]" && handover_has "open=0 masked=0 release=true"'
  shot eu-13-handover-decided

  # A release that fails after the first mask keeps that mask; the retry masks the rest and releases.
  touch "$STATE/mask-fails"
  act test-handover-release
  check "a failed mask stops the release, and nothing crosses" 'wait_handover "phase=failed" 20 && [ ! -e "$SANDBOX/Code/zeus/clients/acme/handoff" ]'
  act test-handover-retry
  check "the retry keeps the mask that was made, and the choices" 'wait_handover "phase=review" 20 && handover_has "groups=[\"number:mask\", \"known-value:keep\"]" && handover_has "masked=1 release=true"'
  act test-handover-release
  check "the app masks and releases the handover" 'wait_for "handover: released [0-9TZa-f-]* of acme files=2 masked=1" 20'
  shot eu-14-released
  released="$SANDBOX/Code/zeus/clients/acme/handoff/from-eu/$id"
  check "the released files are the masked copies with the hashes of the app's manifest" \
    'python3 -c "import hashlib,json,sys; m=json.load(open(sys.argv[1])); sys.exit(0 if all(hashlib.sha256(open(sys.argv[2]+\"/\"+f[\"path\"],\"rb\").read()).hexdigest()==f[\"sha256\"] for f in m[\"files\"]) else 1)" "$app_root/acme/$id/manifest.json" "$released" && grep -q "masked-number-1" "$released/summary.md" && grep -q "masked-number-2" "$released/summary.md" && ! grep -q "4711\|9876" "$released/summary.md"'
  check "released.json records kinds and counts, never a group ID" \
    'python3 -c "import json,sys; r=json.load(open(sys.argv[1])); sys.exit(0 if [f[\"path\"] for f in r[\"files\"]]==[\"summary.md\",\"files/work/view/spec.json\"] and r[\"kept\"]==[{\"kind\":\"known-value\",\"count\":1}] and r[\"masked\"]==[{\"kind\":\"number\",\"count\":2}] and r[\"summary_edited_in_app\"] and r[\"project\"]==\"acme\" and \"accepted_findings\" not in r and \"removed\" not in r and r[\"removed_count\"]==0 else 1)" "$released/released.json" && ! grep -Eq "g[0-9a-f]{15}" "$released/released.json"'
  check "the EU copy of released.json keeps the removed paths" \
    'python3 -c "import json,sys; r=json.load(open(sys.argv[1])); sys.exit(0 if r[\"removed\"]==[] and r[\"removed_count\"]==0 and r[\"id\"]==sys.argv[2] else 1)" "$SANDBOX/Code/zeus-eu/clients/acme/handoff/$id/released.json" "$id"'
  check "the EU handover is closed" '[ -f "$SANDBOX/Code/zeus-eu/clients/acme/handoff/$id/released.json" ] && act test-handover-refresh && wait_handover "projects=[\"acme:false\"]" 10'
  check "no EU chat or other EU file is in the Standard workspace" '[ "$(find "$SANDBOX/Code/zeus" -type f -not -path "*/.git/*" | sed "s|^$SANDBOX/Code/zeus/||" | sort | tr "\n" " ")" = "clients/acme/handoff/from-eu/$id/files/work/view/spec.json clients/acme/handoff/from-eu/$id/released.json clients/acme/handoff/from-eu/$id/summary.md clients/acme/project.json scripts/zeus.py " ]'

  # Back to Standard from the handover window: the EU tabs stop, are kept for the way back, and never resume in Standard.
  eu_sessions="$(awk '$2=="session" {print $3}' "$STATE/sessions" | sort -u)"
  need "the chat page of each tab answers before the switch" 'pages_answer'
  act test-handover-switch
  check "Switch to Standard after a release does not offer the handover again" 'wait_for "mode: switch to standard after a release" 10 && [ "$(grep -c "mode: switch to standard asked" "$TRACE")" = 1 ]'
  need "Standard mode starts again" 'wait_for "mode: now standard" 30'
  check "the Standard tab opens again with its own chat" 'wait_file_has " resume $standard_session" "$STATE/sessions" 20'
  check "no EU chat resumes in Standard" 'for s in $eu_sessions; do [ "$s" = "$standard_session" ] && continue; ! grep -q " resume $s" "$STATE/sessions" || exit 1; done'
  eu_tabs="$SANDBOX/.zeus/eu/editor/app/tabs-eu.json"
  check "the EU tabs are kept for EU mode only, in the EU editor state" '[ -f "$eu_tabs" ] && grep -q "\"mode\":\"eu\"" "$eu_tabs" && ! grep -q "\"mode\":\"standard\"" "$eu_tabs" && [ "$(stat -f %Lp "$(dirname "$eu_tabs")")" = 700 ]'
  check "no EU tab (with its unsent text) is in the app folder" '[ -z "$(grep -l "\"mode\":\"eu\"" "$SANDBOX/Library/Application Support/Zeus/"*.json 2>/dev/null)" ]'
  check "the title bar shows Standard without a cost" 'sleep 1 && mode_bar_has "mode=standard enabled=true pill=false access=- cost=-"'
  act test-store
  check "the Standard pages have the default web data again" 'wait_count "web data: standard persistent=true default=true" 2 10'
  check "the Standard tab got its unsent text back" 'wait_for "restore: [0-9]* message box text back=true" 10'
  act test-clear
  sleep 0.5
  stop_app
  check "quit stops every session (a session that failed its EU start ended by itself)" \
    '[ "$(grep -c " stop " "$STATE/sessions")" -eq $(( $(grep -c " start " "$STATE/sessions") - $(grep -c " preflight-failed " "$STATE/sessions") )) ]'

  # The mode stays across app starts.
  defaults write "$PREFS_DOMAIN" zeusMode -string eu
  launch_app eu-again
  check "the app starts again in EU mode, as it was left" 'wait_for "launched: .* mode=eu" 10 && wait_for "session [0-9]* started (eu)" 20'
  # The quit waits for the chat page: a quit while the page loads is deferred, because the page can not answer yet.
  check "the EU chat page loads after the start" 'newest_page_loaded $PAGE_LOAD_LIMIT && sleep 1'
  check "no Standard session starts in EU mode" '! grep -q "started (standard)" "$TRACE"'
  stop_app
}
