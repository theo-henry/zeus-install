#!/bin/bash
# Test of step 7 of install.sh on a Mac that has Claude Code: the installer updates it to the newest version
# with the method that installed it (claude update, npm, or Homebrew), never with sudo, and within a time
# limit. A failed or stopped update is a warning, and the installer continues.
#
# install.sh is loaded with ZEUS_INSTALL_SOURCED=1 and step 7 runs against simulated claude, npm, brew, and sudo
# commands in a temporary home folder. The real Claude Code of this Mac is not used or changed.
#
# Usage: app/test/claude-update/run.sh

# check runs its test, in single quotes, with eval; ShellCheck does not see the variables in it.
# shellcheck disable=SC2016
set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$TEST_DIR/../../.." && pwd)"
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/zeus-claude-update.XXXXXX")" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
export ZEUS_INSTALL_SOURCED=1

FAILURES=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

# The simulated tools write each call to $CALLS. $STATE/version is the installed Claude Code version, and
# $STATE/newest is the newest version. $STATE/mode is the result of the update: ok, fail, eacces, or hang.
# A hung update starts a child process ("sleep 4713"), so that the test can see that the time limit stops it too.
mkdir -p "$WORK/tools"
cat >"$WORK/tools/claude" <<'TOOL'
#!/bin/bash
printf 'claude %s\n' "$*" >>"$CALLS"
case "${1:-}" in
  --version) printf '%s (Claude Code)\n' "$(cat "$STATE/version")" ;;
  update)
    case "$(cat "$STATE/mode")" in
      fail) echo "Error: the update server is not available (simulated)" >&2; exit 1 ;;
      hang) sleep 4713 & wait ;;
    esac
    if [ "$(cat "$STATE/version")" = "$(cat "$STATE/newest")" ]; then
      echo "Claude Code is up to date ($(cat "$STATE/version"))"
    else
      cp "$STATE/newest" "$STATE/version"
      echo "Successfully updated to version $(cat "$STATE/version")"
    fi
    ;;
  *) echo "ok (simulated)" ;;
esac
TOOL
cat >"$WORK/tools/npm" <<'TOOL'
#!/bin/bash
printf 'npm %s\n' "$*" >>"$CALLS"
if [ "$(cat "$STATE/mode")" = "eacces" ]; then
  echo "npm error code EACCES" >&2
  echo "npm error Error: EACCES: permission denied, rename '/usr/local/lib/node_modules/@anthropic-ai/claude-code'" >&2
  exit 243
fi
cp "$STATE/newest" "$STATE/version"
echo "changed 1 package (simulated)"
TOOL
cat >"$WORK/tools/brew" <<'TOOL'
#!/bin/bash
printf 'brew %s\n' "$*" >>"$CALLS"
cp "$STATE/newest" "$STATE/version"
echo "==> Upgrading 1 outdated package (simulated)"
TOOL
cat >"$WORK/tools/sudo" <<'TOOL'
#!/bin/bash
printf 'sudo %s\n' "$*" >>"$CALLS"
exit 1
TOOL
chmod +x "$WORK/tools/"*

# setup <name> <method> <version> <newest> <mode>: a new home folder with Claude Code installed with <method>:
#   native     ~/.local/bin/claude -> ~/.local/share/claude/versions/<version>, as the Claude Code installer does
#   npm        <prefix>/bin/claude -> ../lib/node_modules/@anthropic-ai/claude-code/cli.js, with npm in <prefix>/bin
#   homebrew   <brew>/bin/claude -> ../Caskroom/claude-code/<version>/claude, with brew in <brew>/bin
# PATH has the folder of the claude command, then a folder with sudo, then the system folders.
setup() {
  local name="$1" method="$2" dir bin
  dir="$WORK/$name"
  export HOME="$dir/home" STATE="$dir/state" CALLS="$dir/calls"
  mkdir -p "$HOME/Library/Logs/zeus-install" "$STATE" "$dir/sudo-bin"
  printf '%s\n' "$3" >"$STATE/version"
  printf '%s\n' "$4" >"$STATE/newest"
  printf '%s\n' "$5" >"$STATE/mode"
  : >"$CALLS"
  cp "$WORK/tools/sudo" "$dir/sudo-bin/sudo"
  case "$method" in
    native)
      bin="$HOME/.local/bin"
      mkdir -p "$bin" "$HOME/.local/share/claude/versions"
      cp "$WORK/tools/claude" "$HOME/.local/share/claude/versions/$3"
      ln -s "$HOME/.local/share/claude/versions/$3" "$bin/claude"
      ;;
    npm)
      bin="$dir/npm-global/bin"
      mkdir -p "$bin" "$dir/npm-global/lib/node_modules/@anthropic-ai/claude-code"
      cp "$WORK/tools/claude" "$dir/npm-global/lib/node_modules/@anthropic-ai/claude-code/cli.js"
      ln -s ../lib/node_modules/@anthropic-ai/claude-code/cli.js "$bin/claude"
      cp "$WORK/tools/npm" "$bin/npm"
      ;;
    homebrew)
      bin="$dir/homebrew/bin"
      mkdir -p "$bin" "$dir/homebrew/Caskroom/claude-code/$3"
      cp "$WORK/tools/claude" "$dir/homebrew/Caskroom/claude-code/$3/claude"
      ln -s "../Caskroom/claude-code/$3/claude" "$bin/claude"
      cp "$WORK/tools/brew" "$bin/brew"
      ;;
  esac
  export PATH="$bin:$dir/sudo-bin:/usr/bin:/bin:/usr/sbin:/sbin"
  OUT="$dir/out"
}

# run_step [app]: runs step 7 of install.sh, and then a line that shows that the installer continued.
# With "app", in app mode (ZEUS_INSTALL_APP=1). The output (stdout and stderr) is in $OUT.
run_step() {
  local app_mode=""
  if [ "${1:-}" = "app" ]; then app_mode=1; fi
  (
    ZEUS_INSTALL_APP="$app_mode"
    # shellcheck source=install.sh
    source "$REPO_DIR/install.sh"
    install_claude
    printf 'SUMMARY: %s\n' "${SUMMARY[@]}"
    echo "the installer continues"
  ) >"$OUT" 2>&1
}

no_sudo() { ! grep -q '^sudo' "$CALLS"; }
continued() { grep -q "the installer continues" "$OUT"; }

printf '\nNative install, older version: claude update\n'
setup native-old native 2.1.0 2.1.5 ok
run_step
check "the step ran claude update" 'grep -qx "claude update" "$CALLS"'
check "the step did not use npm, Homebrew, or the Claude Code installer" '! grep -qE "^(npm|brew) " "$CALLS" && ! grep -q "Claude Code installed" "$OUT"'
check "the summary shows the old and the new version" 'grep -q "SUMMARY: done      Claude Code (updated from 2.1.0 to 2.1.5)" "$OUT"'
check "Claude Code is now the newest version" '[ "$(cat "$STATE/version")" = 2.1.5 ]'
check "the update output is in the log" 'grep -q "Successfully updated to version 2.1.5" "$HOME/Library/Logs/zeus-install/claude-update.log"'
check "no sudo" 'no_sudo'
check "the installer continues" 'continued'

printf '\nNative install, already the newest version\n'
setup native-current native 2.1.5 2.1.5 ok
run_step
check "the step ran claude update" 'grep -qx "claude update" "$CALLS"'
check "the summary shows that it is up to date, with the version" 'grep -q "SUMMARY: skipped   Claude Code (up to date, 2.1.5)" "$OUT"'
check "the installer continues" 'continued'

printf '\nnpm install: npm updates it in the same folder\n'
setup npm-old npm 2.0.10 2.1.5 ok
run_step
check "the step ran npm install -g with the prefix of the installed Claude Code" \
  'grep -qx "npm install -g --prefix $WORK/npm-old/npm-global --allow-scripts=@anthropic-ai/claude-code --no-fund --no-audit @anthropic-ai/claude-code@latest" "$CALLS"'
check "the step did not run claude update (no change of the install method)" '! grep -qx "claude update" "$CALLS"'
check "the summary shows the old and the new version" 'grep -q "SUMMARY: done      Claude Code (updated from 2.0.10 to 2.1.5)" "$OUT"'
check "no sudo" 'no_sudo'

printf '\nnpm install in a folder that needs sudo\n'
setup npm-eacces npm 2.0.10 2.1.5 eacces
run_step
check "the step tells the user not to use sudo" 'grep -q "could not be updated without sudo. Do not use sudo" "$OUT"'
check "the summary shows the installed version, not updated" 'grep -q "SUMMARY: skipped   Claude Code (2.0.10, not updated)" "$OUT"'
check "the step shows the update command for later" 'grep -q "To update it later, run: $WORK/npm-eacces/npm-global/bin/npm install -g" "$OUT"'
check "no sudo" 'no_sudo'
check "the installer continues" 'continued'

printf '\nHomebrew install: brew upgrades the cask\n'
setup brew-old homebrew 2.1.0 2.1.5 ok
run_step
check "the step ran brew upgrade --cask claude-code" 'grep -qx "brew upgrade --cask claude-code" "$CALLS"'
check "the step did not run claude update or npm" '! grep -qx "claude update" "$CALLS" && ! grep -q "^npm " "$CALLS"'
check "the summary shows the old and the new version" 'grep -q "SUMMARY: done      Claude Code (updated from 2.1.0 to 2.1.5)" "$OUT"'

printf '\nA failed update\n'
setup native-fail native 2.1.0 2.1.5 fail
run_step
check "the step shows a warning and the log" 'grep -q "Warning: Claude Code could not be updated." "$OUT" && grep -q "See the log: .*claude-update.log" "$OUT"'
check "the log has the error" 'grep -q "update server is not available" "$HOME/Library/Logs/zeus-install/claude-update.log"'
check "the summary shows the installed version, not updated" 'grep -q "SUMMARY: skipped   Claude Code (2.1.0, not updated)" "$OUT"'
check "the installer continues" 'continued'

printf '\nAn update that does not finish\n'
setup native-hang native 2.1.0 2.1.5 hang
started=$SECONDS
ZEUS_INSTALL_CLAUDE_UPDATE_TIMEOUT=2 run_step
check "the time limit stops the update (took $((SECONDS - started)) s)" '[ $((SECONDS - started)) -lt 15 ]'
check "the step shows a warning" 'grep -q "Warning: the update of Claude Code did not finish in 2 seconds" "$OUT"'
check "the summary shows the installed version, not updated" 'grep -q "SUMMARY: skipped   Claude Code (2.1.0, not updated)" "$OUT"'
check "no process of the update stays" 'sleep 1 && ! pgrep -f "^sleep 4713$" >/dev/null'
check "the installer continues" 'continued'

printf '\nApp mode (Zeus.app)\n'
setup app-old native 2.1.0 2.1.5 ok
run_step app
check "the app gets the running and done lines of step 7" \
  'grep -qx "@@zeus running 7 Claude Code" "$OUT" && grep -qx "@@zeus done 7 Claude Code (updated from 2.1.0 to 2.1.5)" "$OUT"'
(ZEUS_INSTALL_APP=1; source "$REPO_DIR/install.sh"; check_steps) >"$OUT.check" 2>&1 || true
check "the app check shows step 7 as done when Claude Code is installed" 'grep -qx "@@zeus state 7 ok" "$OUT.check"'
setup app-fail native 2.1.0 2.1.5 fail
run_step app
check "a failed update is skipped in the app, not failed" \
  'grep -qx "@@zeus skipped 7 Claude Code (2.1.0, not updated)" "$OUT" && ! grep -q "@@zeus failed" "$OUT"'

printf '\n'
if [ "$FAILURES" -gt 0 ]; then
  printf '%s check(s) failed.\n' "$FAILURES"
  exit 1
fi
echo "All checks passed."
