#!/bin/bash
# Regression test: install.sh adds every plugin and marketplace for the user (--scope user), so it never
# changes the tracked .claude/settings.json of the Zeus folder. A change to that file stops
# git pull --ff-only, and then Zeus cannot update itself.
#
# install.sh is loaded with ZEUS_INSTALL_SOURCED=1 and its plugin steps run against a simulated claude CLI.
# The simulated CLI rewrites .claude/settings.json in the current folder for each plugin install or
# marketplace add without --scope user, as Claude Code does at project scope. The real home folder is not used.
#
# Usage: app/test/plugin-scope/run.sh

# check runs its test, in single quotes, with eval; ShellCheck does not see the variables in it.
# shellcheck disable=SC2016
set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$TEST_DIR/../../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/zeus-plugin-scope.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

FAILURES=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

export HOME="$WORK/home"
export CALLS="$WORK/calls"
ZEUS_FOLDER="$HOME/Code/zeus"
SETTINGS="$ZEUS_FOLDER/.claude/settings.json"
mkdir -p "$WORK/bin" "$ZEUS_FOLDER/.claude" "$HOME/Library/Logs/zeus-install"
: >"$CALLS"
printf '{\n  "enabledPlugins": {\n    "zeus-editor@zeus-editor": true\n  },\n  "extraKnownMarketplaces": {}\n}\n' >"$SETTINGS"
cp "$SETTINGS" "$WORK/settings.orig"

cat >"$WORK/bin/claude" <<'CLAUDE'
#!/bin/bash
# Simulated Claude Code CLI. It writes each call to $CALLS, one line for each call.
printf '%s\n' "$*" >>"$CALLS"
scope=""
args=("$@")
for i in "${!args[@]}"; do
  case "${args[$i]}" in
    --scope | -s) scope="${args[$((i + 1))]:-}" ;;
    --scope=*) scope="${args[$i]#--scope=}" ;;
  esac
done
case "$1 $2" in
  "plugin list") [ -f "$CALLS.installed" ] && cat "$CALLS.installed"; exit 0 ;;
  "plugin install") echo "$3" >>"$CALLS.installed" ;;
esac
case "$1 $2 ${3:-}" in
  "plugin install "* | "plugin marketplace add" | "plugin update "*)
    # Project scope: Claude Code writes the settings file of the current folder again, in its own key order.
    if [ "$scope" != "user" ] && [ -f .claude/settings.json ]; then
      printf '{"extraKnownMarketplaces":{},"enabledPlugins":{"zeus-editor@zeus-editor":true,"%s":true}}\n' "$3" >.claude/settings.json
    fi
    ;;
esac
echo "ok (simulated)"
CLAUDE
chmod +x "$WORK/bin/claude"
export PATH="$WORK/bin:$PATH"

# Runs install.sh functions in the Zeus folder, with app mode as given in $1 (1 or empty).
run_install() {
  local app_mode="$1"
  shift
  (
    cd "$ZEUS_FOLDER"
    export ZEUS_INSTALL_SOURCED=1 ZEUS_INSTALL_APP="$app_mode"
    # shellcheck source=install.sh
    source "$REPO_DIR/install.sh"
    "$@"
  )
}

printf '\nApp mode: the Zeus Editor plugin and the skill plugins\n'
run_install 1 install_editor_plugin >/dev/null 2>&1
run_install 1 install_editor_plugin >/dev/null 2>&1 # Second run: the update path.
run_install 1 install_skill_plugins >/dev/null 2>&1
check "claude plugin install ran for each plugin" '[ "$(grep -c "^plugin install " "$CALLS")" -eq 4 ]'
check "claude plugin update ran" 'grep -q "^plugin update " "$CALLS"'
check "each plugin install, update, and marketplace add uses --scope user" \
  '! grep -E "^plugin (install|update|marketplace add) " "$CALLS" | grep -vE -- "--scope user( |$)"'
check ".claude/settings.json of the Zeus folder did not change" 'cmp -s "$SETTINGS" "$WORK/settings.orig"'

printf '\nTerminal use: the next steps for the skill plugins\n'
NEXT="$(run_install "" eval 'record done "Zeus folder"; print_summary' 2>&1)"
check "no /plugin install line (it can install at project scope)" '! grep -q "/plugin install" <<<"$NEXT"'
COMMANDS="$(sed -n 's/^ *\(claude plugin .*\)$/\1/p' <<<"$NEXT")"
check "a marketplace add and a plugin install line for each skill plugin" '[ "$(grep -c . <<<"$COMMANDS")" -eq 6 ]'
check "each line uses --scope user" '! grep -vE -- "--scope user$" <<<"$COMMANDS"'
: >"$CALLS"
(cd "$ZEUS_FOLDER" && while IFS= read -r line; do read -ra words <<<"$line"; "${words[@]}" >/dev/null; done <<<"$COMMANDS")
check "the lines, typed in the Zeus folder, did not change .claude/settings.json" 'cmp -s "$SETTINGS" "$WORK/settings.orig"'

printf '\nThe test detects a project-scope install\n'
(cd "$ZEUS_FOLDER" && claude plugin install celonis-pql@celonis-pql >/dev/null)
check "the simulated claude changes .claude/settings.json without --scope user" '! cmp -s "$SETTINGS" "$WORK/settings.orig"'

printf '\n'
if [ "$FAILURES" -gt 0 ]; then
  printf '%s check(s) failed.\n' "$FAILURES"
  exit 1
fi
echo "All checks passed."
