# Google sign-in step of the setup on a simulated Mac (app/test/sim/run.sh --signin). Sourced by run.sh: it uses its
# helpers (act, check, need, wait_for, wait_count, start_app, stop_app, shot, ...) and its simulated tools. No Google
# service is called: gcloud is payload/gcloud, and the access check and the account come from stubs/curl
# ($STATE/google-access: "none" is an account without the two roles of the EU project).
# check runs its test, in single quotes, with eval; ShellCheck does not see the variables in it.
# shellcheck disable=SC2016,SC2034,SC2154

# setup_round <number>: clicks Install (or Update and check again) and waits for the start of round <number> of the
# setup in this app run. The first round answers the Anaconda license and the GitHub login.
setup_round() {
  act setup-install
  wait_count "setup event: running 1 " "$1" 30 >/dev/null || return 1
  if [ "$1" = 1 ]; then
    wait_for "setup event: ask 2 " 40 >/dev/null && act setup-answer-yes
    wait_for "setup event: running 4 " 40 >/dev/null && sleep 1 && act setup-enter
  fi
}

# setup_ended <number>: setup round <number> of this app run ended without an error.
setup_ended() { wait_count "setup ended: check=false code=0" "$1" 120; }

# signin_terminal: the Google sign-in step as in Terminal use, in the simulated home folder and without a keyboard
# (no controlling terminal): a question there would fail. Prints the output and the summary.
signin_terminal() {
  env HOME="$SANDBOX" PATH="$SANDBOX/.local/bin:$SANDBOX/.local/node/bin:$SIM_DIR/stubs:/usr/bin:/bin" \
    ZEUS_SIM_STATE="$STATE" ZEUS_SIM_PAYLOAD="$SIM_DIR/payload" \
    python3 -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' \
    bash -c 'ZEUS_INSTALL_SOURCED=1 source "$1"; WORK_DIR="$(mktemp -d)"; install_eu; echo after-eu; printf "%s\n" "${SUMMARY[@]}"' \
    _ "$REPO_DIR/install.sh" 2>&1
}

signin_scenario() {
  local adc out
  echo
  echo "Scenario sign-in: skip, a remembered skip, no access, the setup again after the roles, and an existing sign-in"
  start_app signin
  adc="$SANDBOX/.config/gcloud/application_default_credentials.json"
  need "the setup window checks this Mac" 'wait_for "setup ended: check=true code=0" 30'
  check "the check finds the Google sign-in to do on a new Mac" 'grep -q "setup event: state 17 todo" "$TRACE"'

  # Skip: a user who does not use EU mode.
  setup_round 1
  need "step 17: the installer asks for the Google sign-in" 'wait_for "setup event: ask 17 " 150'
  shot signin-1-question
  act setup-answer-no
  check "Skip skips the Google sign-in, and the setup completes" \
    'wait_for "setup event: skipped 17 Google sign-in (EU mode, skipped)" 20 && setup_ended 1 && [ "$(grep -c "setup event: failed " "$TRACE")" = 0 ]'
  check "Skip runs no Google sign-in" '! grep -q "application-default login" "$STATE/gcloud.log" && [ ! -e "$adc" ]'
  check "the skip is kept" '[ -f "$SANDBOX/.zeus/eu/google-sign-in-skipped" ]'
  shot signin-2-skipped
  setup_round 2
  check "the setup again does not ask after a skip" \
    'wait_count "setup event: skipped 17 Google sign-in (EU mode, skipped)" 2 120 && setup_ended 2 && [ "$(grep -c "setup event: ask 17 " "$TRACE")" = 1 ]'

  # No access: the sign-in completes, but the account has not the two roles. The message names the account, and the
  # setup completes; EU mode is not ready.
  rm -f "$SANDBOX/.zeus/eu/google-sign-in-skipped"
  printf 'none\n' >"$STATE/google-access"
  setup_round 3
  need "after the skip is removed, the installer asks again" 'wait_count "setup event: ask 17 " 2 120'
  act setup-answer-yes
  check "the Google sign-in runs" 'wait_for "setup event: failed 17 " 30 && [ "$(grep -c "^auth application-default login$" "$STATE/gcloud.log")" = 1 ]'
  check "an account without access gets the message for the two roles, with the account" \
    'grep -q "setup event: failed 17 Your Google account sim@example.com has no access to the EU project of Zeus. Ask the Zeus maintainer for the Vertex AI User and Service Usage Consumer roles.$" "$TRACE"'
  check "without access, the setup still completes" 'setup_ended 3'
  check "without access, the EU project is not the quota project" '! grep -q quota_project_id "$adc"'
  shot signin-3-no-access

  # The maintainer gives the roles: the setup again finds the sign-in, checks the access, and sets the quota project,
  # without a question and without a second sign-in.
  rm -f "$STATE/google-access"
  setup_round 4
  check "after the roles, the setup again completes the step without a question or a new sign-in" \
    'wait_for "setup event: done 17 Google sign-in (EU mode, sim@example.com)" 120 && setup_ended 4 && [ "$(grep -c "setup event: ask 17 " "$TRACE")" = 2 ] && [ "$(grep -c "^auth application-default login$" "$STATE/gcloud.log")" = 1 ]'
  check "the EU project is then the quota project" 'grep -q "\"quota_project_id\": \"project-4bf0bacd-fec4-406b-a99\"" "$adc"'
  shot signin-4-access

  # An existing sign-in with access: nothing to do and no question.
  setup_round 5
  check "a Mac that is signed in skips the step without a question" \
    'wait_for "setup event: skipped 17 Google sign-in (EU mode, sim@example.com)" 120 && setup_ended 5 && [ "$(grep -c "setup event: ask 17 " "$TRACE")" = 2 ] && [ "$(grep -c "^auth application-default login$" "$STATE/gcloud.log")" = 1 ]'
  # The whole output first, then grep: with pipefail, grep -q can end the pipe before install.sh ends (SIGPIPE).
  out="$(env HOME="$SANDBOX" PATH="$SANDBOX/.local/bin:$SANDBOX/.local/node/bin:$SIM_DIR/stubs:/usr/bin:/bin" ZEUS_SIM_STATE="$STATE" ZEUS_SIM_PAYLOAD="$SIM_DIR/payload" ZEUS_INSTALL_APP=1 bash "$REPO_DIR/install.sh" --check 2>&1 || true)"
  check "install.sh --check finds the sign-in done" 'printf "%s" "$out" | grep -q "@@zeus state 17 ok"'
  stop_app

  # Terminal use (no Zeus app): the same results, as warnings that do not stop the setup.
  out="$(signin_terminal)"
  check "in Terminal use, a Mac that is signed in gets no question" \
    'printf "%s" "$out" | grep -q "^skipped   Google sign-in (EU mode, sim@example.com)$" && printf "%s" "$out" | grep -q "^after-eu$" && ! printf "%s" "$out" | grep -q "keyboard"'
  printf 'none\n' >"$STATE/google-access"
  out="$(signin_terminal)"
  check "in Terminal use, no access is a warning with the message for the roles, and the setup goes on" \
    'printf "%s" "$out" | grep -q "Warning:.* Your Google account sim@example.com has no access to the EU project of Zeus. Ask the Zeus maintainer" && printf "%s" "$out" | grep -q "^after-eu$" && printf "%s" "$out" | grep -q "^warning   Google sign-in of EU mode (not set up; EU mode only)$" && ! printf "%s" "$out" | grep -q "Stopped:"'
  rm -f "$STATE/google-access"
  touch "$STATE/google-token-expired"
  out="$(signin_terminal)"
  check "in Terminal use without a keyboard, an expired sign-in is skipped with a note, and the setup goes on" \
    'printf "%s" "$out" | grep -q "No keyboard is connected" && printf "%s" "$out" | grep -q "^skipped   Google sign-in (EU mode, skipped)$" && printf "%s" "$out" | grep -q "^after-eu$" && [ ! -f "$SANDBOX/.zeus/eu/google-sign-in-skipped" ]'
  check "the access check never puts the token on a command line" '! grep -q "sim-access-token" "$STATE/curl.log"'
}
