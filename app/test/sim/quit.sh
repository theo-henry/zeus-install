# Quit scenario of the app on a simulated Mac (app/test/sim/run.sh --quit). Sourced by run.sh: it uses its helpers
# (act, check, need, wait_for, launch_app, ...) and eu_sandbox of eu.sh for an installed Mac.
# The quit question is a sheet on the window of the first unsafe tab. When that window closes while the question shows
# (the tab's Zeus session ended, for example with Stop in the menu bar item), AppKit does not call the sheet's
# completion handler: the quit must end there, so that a later quit asks again or quits.
# check runs its test, in single quotes, with eval; ShellCheck does not see the variables in it.
# shellcheck disable=SC2016,SC2034,SC2154

# zeus_pid <n>: the process of the n-th simulated zeus session that started.
zeus_pid() { awk '$2 == "start" { print $1 }' "$STATE/sessions" | sed -n "${1}p"; }

quit_scenario() {
  echo
  echo "Scenario quit: the window of the quit question closes, then a later quit"
  eu_sandbox
  launch_app quit
  need "the app opens a chat" 'wait_for "page loaded: http://127.0.0.1" 30 && sleep 1'
  act test-draft
  sleep 0.5
  act quit
  need "a quit asks about the unsent text" 'wait_for "quit deferred: .*composer-draft" 10'
  shot quit-1-question
  # The session of the tab ends while the question shows: the tab closes, and its window with it.
  kill -TERM "$(zeus_pid 1)"
  need "the tab's session ends and its window closes with the question" 'wait_for "state: ended" 10 && sleep 1'
  act new-chat
  need "a new chat opens" 'wait_starts 2 && wait_count "page loaded: http://127.0.0.1" 2 20 && sleep 1'
  act quit
  local waited=0
  while kill -0 "$APP_PID" 2>/dev/null && [ "$waited" -lt 30 ]; do sleep 0.5; waited=$((waited + 1)); done
  check "a later quit stops the new session and the app quits" '! kill -0 "$APP_PID" 2>/dev/null && wait_stops 2'
  kill -0 "$APP_PID" 2>/dev/null && kill "$APP_PID"
  APP_PID=""
  check "the quit ended with the window of its question" 'grep -q "quit cancelled: the window of the question closed" "$TRACE"'
  if [ -n "$SHOTS" ]; then cp "$TRACE" "$SHOTS/trace-quit.log"; fi
}
