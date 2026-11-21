#!/bin/bash
# Test of the step table of install.sh (STEP_TABLE) and of its "@@zeus" lines for the app:
#   - the steps, their numbers, and their order in Terminal use, app mode, and --app-only;
#   - main runs the steps in the order of the table (run_steps, run_install_step);
#   - --check gives the plan, one result for each step, and "end ok";
#   - a failure outside a step is "failed -", and the run ends with "end failed";
#   - the step github-login ends after gh auth setup-git, so that it never reports a result and then fails;
#   - after an EU step, a failure is not reported as a failure of that step.
# install.sh is loaded with ZEUS_INSTALL_SOURCED=1 or runs in an empty temporary home folder with simulated tools.
# Nothing is installed.

# check runs its test, in single quotes, with eval; ShellCheck does not see the variables in it.
# shellcheck disable=SC2016
set -euo pipefail
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$TEST_DIR/../../.." && pwd)"
INSTALLER="$REPO_DIR/install.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/zeus-install-steps.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

FAILURES=0
# Without pipefail: grep -q stops reading early, and the command before it then fails with SIGPIPE.
check() {
  if (set +o pipefail; eval "$2"); then
    printf '  PASS %s\n' "$1"
  else
    printf '  FAIL %s\n' "$1"
    FAILURES=$((FAILURES + 1))
  fi
}

# sourced <mode env...> -- <commands>: runs the commands with install.sh loaded, in an empty home folder.
sourced() {
  # One fixed variable, so that the list is never empty (bash 3.2 and set -u).
  local -a env=(ZEUS_INSTALL_STEPS_TEST=1)
  while [ "$1" != -- ]; do env+=("$1"); shift; done
  shift
  mkdir -p "$WORK/home"
  env HOME="$WORK/home" PATH="$WORK/bin:/usr/bin:/bin" "${env[@]}" ZEUS_INSTALL_SOURCED=1 \
    bash -c 'source "$1"; WORK_DIR="$(mktemp -d)"; set +e; eval "$2"' _ "$INSTALLER" "$1" 2>&1
}

TERMINAL_KEYS="xcode anaconda gh github-login repo-access node claude content-cli workspace editor-plugin zeus-command gcloud eu-plugins google-sign-in app"
APP_KEYS="xcode anaconda gh github-login repo-access node claude content-cli workspace editor-plugin zeus-command skill-plugins claude-login gcloud eu-plugins google-sign-in"
APP_ONLY_KEYS="xcode anaconda gh github-login repo-access app"

echo "The steps of each mode"
keys_of() { awk '{ printf "%s%s", (NR > 1 ? " " : ""), $2 }'; }
check "Terminal use: 15 steps, the EU steps 12 to 14, the Zeus app 15" \
  '[ "$(sourced -- step_rows | keys_of)" = "$TERMINAL_KEYS" ] && [ "$(sourced -- "echo \$TOTAL_STEPS")" = 15 ] &&
   sourced -- step_rows | grep -qx "12 gcloud eu_install_gcloud Google Cloud CLI (EU mode)" &&
   sourced -- step_rows | grep -qx "15 app install_zeus_app Zeus app"'
check "app mode: 16 steps, the skill plugins 12, the Claude login 13, the EU steps 14 to 16" \
  '[ "$(sourced ZEUS_INSTALL_APP=1 -- step_rows | keys_of)" = "$APP_KEYS" ] &&
   [ "$(sourced ZEUS_INSTALL_APP=1 -- "echo \$TOTAL_STEPS")" = 16 ] &&
   sourced ZEUS_INSTALL_APP=1 -- step_rows | grep -qx "12 skill-plugins install_skill_plugins Zeus skill plugins" &&
   sourced ZEUS_INSTALL_APP=1 -- step_rows | grep -qx "16 google-sign-in eu_sign_in_google Google sign-in (EU mode)"'
# --app-only is the first argument of install.sh.
app_only_rows="$(env HOME="$WORK/home" PATH=/usr/bin:/bin ZEUS_INSTALL_SOURCED=1 bash -c 'source "$1" --app-only; step_rows' _ "$INSTALLER")"
check "--app-only: steps 1 to 5, then the Zeus app 6" \
  '[ "$(printf "%s\n" "$app_only_rows" | keys_of)" = "$APP_ONLY_KEYS" ] && printf "%s\n" "$app_only_rows" | grep -qx "6 app install_zeus_app Zeus app"'
check "each function of the step table exists" \
  '[ -z "$(sourced -- "for f in \$(STEP_MODE=t step_rows | awk \"{print \\\$3}\") \$(STEP_MODE=a step_rows | awk \"{print \\\$3}\"); do declare -F \"\$f\" >/dev/null || echo \"\$f\"; done")" ]'
check "a key that is not in the table of the mode stops with a message" \
  'sourced -- "step skill-plugins" | grep -q "The installer has no step .skill-plugins. in this mode."'

echo "main runs the steps of the table, in order"
# Each step function only reports a result: the lines show the order and the numbers.
stub_steps='for f in $(step_rows | awk "{print \$3}"); do eval "$f() { record skipped \"$f\"; }"; done; run_steps'
expected_lines() {
  local key
  for key in $1; do printf '@@zeus running %s\n@@zeus skipped %s\n' "$key" "$key"; done
}
check "app mode: a running line and a result line for each step, in the order of the table" \
  '[ "$(sourced ZEUS_INSTALL_APP=1 -- "$stub_steps" | grep "^@@zeus" | sed -E "s/^(@@zeus [a-z]+ [a-z-]+).*/\1/")" = "$(expected_lines "$APP_KEYS")" ]'
check "Terminal use: the numbers 1/15 to 15/15, in the order of the table" \
  'sourced -- "$stub_steps" | grep "==> [0-9]*/15 " | head -1 | grep -qF "==> 1/15 Git (Xcode Command Line Tools)" &&
   [ "$(sourced -- "$stub_steps" | grep -c "==> [0-9]*/15 ")" = 15 ] &&
   sourced -- "$stub_steps" | grep -q "==> 15/15 Zeus app" && ! sourced -- "$stub_steps" | grep -q "^@@zeus"'

echo "The check (--check)"
mkdir -p "$WORK/check-home"
check_out="$(env HOME="$WORK/check-home" PATH=/usr/bin:/bin ZEUS_INSTALL_APP=1 bash "$INSTALLER" --check 2>&1 || true)"
events="$(printf '%s\n' "$check_out" | grep "^@@zeus" || true)"
check "the first line is the plan of app mode" '[ "$(printf "%s\n" "$events" | head -1)" = "@@zeus plan $APP_KEYS" ]'
check "the last line is end ok" '[ "$(printf "%s\n" "$events" | tail -1)" = "@@zeus end ok" ]'
check "one check result for each step, in the order of the plan" \
  '[ "$(printf "%s\n" "$events" | grep "^@@zeus state " | cut -d" " -f3 | tr "\n" " " | sed "s/ \$//")" = "$APP_KEYS" ]'
check "each check result is ok, todo, or always" \
  '! printf "%s\n" "$events" | grep "^@@zeus state " | grep -vqE " (ok|todo|always)$"'
check "the check has no other line" '[ "$(printf "%s\n" "$events" | grep -vcE "^@@zeus (plan|state|end) ")" = 0 ]'

echo "A failure outside a step"
fail_out="$(env HOME="$WORK/check-home" PATH=/usr/bin:/bin ZEUS_INSTALL_APP=1 bash "$INSTALLER" --app-only 2>&1 || true)"
check "the failure has no step key, and the run ends with end failed" \
  'printf "%s\n" "$fail_out" | grep -qx "@@zeus failed - --app-only does not work in app mode (ZEUS_INSTALL_APP=1)." &&
   [ "$(printf "%s\n" "$fail_out" | grep "^@@zeus" | tail -1)" = "@@zeus end failed" ]'
check "Terminal use prints no @@zeus line" \
  '! env HOME="$WORK/check-home" PATH=/usr/bin:/bin bash "$INSTALLER" --check 2>&1 | grep -q "^@@zeus"'
check "--eu-status-line is no setup run: no plan and no end" \
  '! env HOME="$WORK/check-home" PATH=/usr/bin:/bin ZEUS_INSTALL_APP=1 bash "$INSTALLER" --eu-status-line 2>&1 | grep -q "^@@zeus"'

echo "The step github-login"
mkdir -p "$WORK/bin"
cat >"$WORK/bin/gh" <<'GH'
#!/bin/bash
case "$*" in
  "auth status -h github.com") exit 0 ;;
  "auth setup-git -h github.com") if [ -n "${SIM_SETUP_GIT_FAILS:-}" ]; then exit 1; fi; exit 0 ;;
esac
exit 0
GH
chmod +x "$WORK/bin/gh"
check "gh auth setup-git fails: the step fails, with no result before the failure" \
  '[ "$(sourced ZEUS_INSTALL_APP=1 SIM_SETUP_GIT_FAILS=1 -- "run_install_step github-login" | grep "^@@zeus")" = "$(printf "%s\n" "@@zeus running github-login GitHub login" "@@zeus failed github-login '"'"'gh auth setup-git'"'"' failed.")" ]'
check "already logged in: the step is skipped after gh auth setup-git" \
  '[ "$(sourced ZEUS_INSTALL_APP=1 -- "run_install_step github-login" | grep "^@@zeus" | tail -1)" = "@@zeus skipped github-login GitHub login" ]'

echo "The EU steps"
check "a failed EU step reports its key, and a later failure has no step key" \
  '[ "$(sourced ZEUS_INSTALL_APP=1 -- "install_gcloud() { fail \"No gcloud\"; }; run_install_step gcloud; fail \"Later\"" | grep "^@@zeus")" = "$(printf "%s\n" "@@zeus running gcloud Google Cloud CLI (EU mode)" "@@zeus failed gcloud No gcloud" "@@zeus failed - Later")" ]'
check "after a result, a failure has no step key" \
  '[ "$(sourced ZEUS_INSTALL_APP=1 -- "step node; record done Node.js; fail \"Later\"" | grep "^@@zeus" | tail -1)" = "@@zeus failed - Later" ]'

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "All checks passed."
  exit 0
fi
echo "$FAILURES checks failed."
exit 1
