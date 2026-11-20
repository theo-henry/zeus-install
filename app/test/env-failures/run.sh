#!/bin/bash
# Test of the three environment failures of install.sh on a Mac that is not set up correctly, and of the
# Macs that are set up correctly (they must not see any change):
#   1. A folder of the user that root owns (~/.config, ~/.config/gh, ~/.npm, ~/.local, ~/.local/bin, ~/.claude):
#      the installer stops before the first step with one exact "sudo chown" line. The installer never runs sudo.
#   2. The Claude login: the command gets the real terminal device as its input, not /dev/tty (Claude Code stops
#      with "EINVAL: invalid argument, kqueue" on /dev/tty). Without a terminal, the installer prints how to log
#      in with the Terminal app, and the login that is already done is skipped.
#   4. The Claude login and the macOS keychain: no default keychain, a missing keychain file, or a locked keychain stops
#      step 13 before the browser opens with the exact fix; a failed login with an unusable keychain shows the same fix.
#   3. content-cli: when the global folder of npm is not writable, it goes to ~/.npm-global, and the command is
#      linked into ~/.local/bin and found in the same run and on the next run.
#      Root-owned files in the npm cache stop the step with the exact "sudo chown" line for ~/.npm.
#
# A folder that root owns is a symbolic link to /private/etc in a temporary home folder: no sudo is needed
# and no real folder changes. install.sh is loaded with ZEUS_INSTALL_SOURCED=1 and runs against simulated
# npm and claude commands. A pseudo terminal (Python pty) stands for the Terminal app.
#
# Usage: app/test/env-failures/run.sh

# check runs its test, in single quotes, with eval; ShellCheck does not see the variables in it.
# shellcheck disable=SC2016
set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$TEST_DIR/../../.." && pwd)"
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/zeus-env-failures.XXXXXX")" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
export ZEUS_INSTALL_SOURCED=1
ROOT_DIR=/private/etc

FAILURES=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

[ "$(stat -f %u "$ROOT_DIR")" = 0 ] || { echo "$ROOT_DIR is not owned by root: the test cannot run."; exit 1; }

# Simulated tools. $STATE/npm: "ok" (the default folder is writable), "eacces" (it is not), or "cache" (the npm
# cache has root-owned files).
mkdir -p "$WORK/tools"
cat >"$WORK/tools/npm" <<'TOOL'
#!/bin/bash
printf 'npm %s\n' "$*" >>"$CALLS"
prefix=""
while [ $# -gt 0 ]; do
  if [ "$1" = "--prefix" ]; then prefix="$2"; fi
  shift
done
if [ "$(cat "$STATE/npm")" = cache ]; then
  echo "npm error code EACCES" >&2
  echo "npm error Your cache folder contains root-owned files, due to a bug in" >&2
  echo "npm error previous versions of npm which has since been addressed. (simulated)" >&2
  exit 243
fi
if [ -z "$prefix" ] && [ "$(cat "$STATE/npm")" = eacces ]; then
  echo "npm error code EACCES" >&2
  echo "npm error Error: EACCES: permission denied, mkdir '/usr/local/lib/node_modules' (simulated)" >&2
  exit 243
fi
bin="${prefix:-$STATE/default-prefix}/bin"
mkdir -p "$bin"
printf '#!/bin/sh\necho content-cli\n' >"$bin/content-cli"
chmod +x "$bin/content-cli"
[ -n "$prefix" ] || { mkdir -p "$STATE/path-bin" && ln -sf "$bin/content-cli" "$STATE/path-bin/content-cli"; }
echo "added 1 package (simulated)"
TOOL
cat >"$WORK/tools/sudo" <<'TOOL'
#!/bin/bash
printf 'sudo %s\n' "$*" >>"$CALLS"
exit 1
TOOL
chmod +x "$WORK/tools/"*

# setup <name> <npm mode>: a new home folder, and a PATH with the simulated tools and the system folders only.
setup() {
  local dir="$WORK/$1"
  export HOME="$dir/home" STATE="$dir/state" CALLS="$dir/calls" OUT="$dir/out"
  mkdir -p "$HOME/Library/Logs/zeus-install" "$STATE" "$dir/bin" "$STATE/path-bin"
  printf '%s\n' "$2" >"$STATE/npm"
  : >"$CALLS"
  cp "$WORK/tools/npm" "$WORK/tools/sudo" "$dir/bin/"
  # The simulated default folder of npm is on PATH only after a successful default install (path-bin).
  export PATH="$dir/bin:$STATE/path-bin:/usr/bin:/bin:/usr/sbin:/sbin"
}

# run <function...>: runs install.sh functions, then prints a line that shows the installer continued.
run() {
  (
    # shellcheck source=install.sh
    source "$REPO_DIR/install.sh"
    WORK_DIR="$STATE"
    use_local_path
    "$@"
    echo "the installer continues"
  ) >"$OUT" 2>&1
}
runs_ok() { run "$@" && grep -q "the installer continues" "$OUT"; }
no_sudo() { ! grep -q '^sudo' "$CALLS"; }

printf '\n1. Folders that root owns\n'
CHOWN_LINE='sudo chown -R $(whoami) ~/.config'
setup root-config ok
ln -s "$ROOT_DIR" "$HOME/.config"
check "a root-owned ~/.config stops the installer" '! run require_owned "$HOME/.config" "$HOME/.local" "$HOME/.npm" "$HOME/.claude"'
check "the stop prints the exact fix line" 'grep -qxF "    $CHOWN_LINE" "$OUT"'
check "the installer does not continue and does not run sudo" '! grep -q "the installer continues" "$OUT" && no_sudo'
check "the stop tells how to run the step again" 'grep -q "run the same install line again" "$OUT"'
setup root-gh ok
mkdir -p "$HOME/.config"
ln -s "$ROOT_DIR" "$HOME/.config/gh"
check "a root-owned ~/.config/gh in an own ~/.config stops with the exact fix line" '! run require_owned "$HOME/.config" "$HOME/.config/gh" "$HOME/.local" && grep -qxF "    sudo chown -R \$(whoami) ~/.config/gh" "$OUT" && no_sudo'
setup root-two ok
ln -s "$ROOT_DIR" "$HOME/.npm"
ln -s "$ROOT_DIR" "$HOME/.claude"
check "root-owned ~/.npm and ~/.claude go into one fix line" '! run require_owned "$HOME/.config" "$HOME/.npm" "$HOME/.claude" && grep -qxF "    sudo chown -R \$(whoami) ~/.npm ~/.claude" "$OUT"'
rm "$HOME/.npm" "$HOME/.claude"
check "after the fix (own folders), the same check passes" 'runs_ok require_owned "$HOME/.config" "$HOME/.npm" "$HOME/.claude"'
setup own-dirs ok
mkdir -p "$HOME/.config/gh" "$HOME/.npm" "$HOME/.local/bin" "$HOME/.claude"
check "own folders: no stop and no output" 'runs_ok require_owned "$HOME/.config" "$HOME/.config/gh" "$HOME/.local" "$HOME/.local/bin" "$HOME/.npm" "$HOME/.claude" && [ "$(cat "$OUT")" = "the installer continues" ]'
setup new-mac ok
check "folders that do not exist yet: no stop and no output" 'runs_ok require_owned "$HOME/.config" "$HOME/.config/gh" "$HOME/.local" "$HOME/.npm" "$HOME/.claude" && [ "$(cat "$OUT")" = "the installer continues" ]'

printf '\n3. content-cli\n'
setup npm-writable ok
check "writable npm folder: the default install runs and the step is done" 'runs_ok install_content_cli && grep -q "Installed." "$OUT"'
check "writable npm folder: no user folder, no link, one npm call" '[ ! -e "$HOME/.npm-global" ] && [ ! -e "$HOME/.local/bin/content-cli" ] && [ "$(grep -c "^npm" "$CALLS")" = 1 ] && no_sudo'
check "writable npm folder: ~/.zprofile is not touched" '[ ! -e "$HOME/.zprofile" ]'
setup npm-eacces eacces
check "unwritable npm folder: the step installs into ~/.npm-global and is done" 'runs_ok install_content_cli && grep -q "Installed." "$OUT" && [ -x "$HOME/.npm-global/bin/content-cli" ]'
check "unwritable npm folder: the command is linked into ~/.local/bin" '[ -L "$HOME/.local/bin/content-cli" ]'
check "unwritable npm folder: the PATH line is in ~/.zprofile, not ~/.zshrc" 'grep -qF ".local/bin" "$HOME/.zprofile" && [ ! -e "$HOME/.zshrc" ]'
check "unwritable npm folder: the installer never runs sudo" 'no_sudo'
check "unwritable npm folder: a new bash with the PATH line finds content-cli" '[ "$(env -i HOME="$HOME" PATH=/usr/bin:/bin bash -c "source \"$HOME/.zprofile\"; content-cli")" = content-cli ]'
check "the next run skips the step" ': >"$CALLS"; runs_ok install_content_cli && grep -q "Already installed." "$OUT" && [ ! -s "$CALLS" ]'
setup npm-cache cache
check "root-owned files in the npm cache: the step stops with the exact fix line for ~/.npm" '! run install_content_cli && grep -qxF "    sudo chown -R \$(whoami) ~/.npm" "$OUT" && no_sudo'
check "root-owned files in the npm cache: no fallback install into ~/.npm-global" '[ ! -e "$HOME/.npm-global" ] && [ "$(grep -c "^npm" "$CALLS")" = 1 ]'
setup npm-other eacces
sed -i '' 's/EACCES/ENOENT/g' "$HOME/../bin/npm"
check "another npm error still stops with the log" '! run install_content_cli && grep -q "The content-cli install failed." "$OUT" && [ ! -e "$HOME/.npm-global" ]'

printf '\n2. Claude login and the terminal\n'
cat >"$WORK/pty.py" <<'PY'
import os, pty, select, sys, time
# Runs a command with a pseudo terminal as its terminal (like the Terminal app) and prints its output.
pid, fd = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash", "-c", sys.argv[1]])
out = b""
end = time.time() + 60
while time.time() < end:
    ready, _, _ = select.select([fd], [], [], 1)
    if ready:
        try:
            data = os.read(fd, 4096)
        except OSError:
            break
        if not data:
            break
        out += data
sys.stdout.write(out.decode(errors="replace").replace("\r", ""))
PY
cat >"$WORK/notty.py" <<'PY'
import os, subprocess, sys
# Runs a command in a new session with no controlling terminal (like the app's Try again, or a start from a
# program), and prints its output.
res = subprocess.run(["bash", "-c", sys.argv[1]], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                     stderr=subprocess.STDOUT, start_new_session=True, text=True)
sys.stdout.write(res.stdout)
sys.exit(res.returncode)
PY
cat >"$WORK/login-probe.sh" <<PROBE
#!/bin/bash
# Stands for "claude auth login": prints the name of its input terminal, and fails like Bun on /dev/tty.
if [ "\$(tty)" = /dev/tty ]; then echo "error: EINVAL: invalid argument, kqueue"; exit 1; fi
echo "login input: \$(tty)"
PROBE
chmod +x "$WORK/login-probe.sh"

setup claude-tty ok
check "with a terminal, the login command gets the real terminal device" 'python3 -I "$WORK/pty.py" "source \"$REPO_DIR/install.sh\"; with_tty \"$WORK/login-probe.sh\"" >"$OUT"; grep -qE "login input: /dev/ttys[0-9]+" "$OUT" && ! grep -q "kqueue" "$OUT"'
setup claude-notty ok
cat >"$HOME/login.sh" <<'LOGIN'
# Step 13 against a claude that is not logged in and has no terminal.
claude() { if [ "$1 $2" = "auth status" ]; then echo '{"loggedIn": false}'; else echo "claude was started"; fi; }
LOGIN
check "without a terminal, the login step stops and tells how to log in in the Terminal app" '! python3 -I "$WORK/notty.py" "source \"$REPO_DIR/install.sh\"; source \"$HOME/login.sh\"; LOG_DIR=\"$HOME\"; login_claude" >"$OUT" && grep -q "Open the Terminal app and run: claude" "$OUT" && ! grep -q "claude was started" "$OUT"'
check "without a terminal, the stop says Try again (app) or the same line (Terminal use)" 'grep -q "run the same install line again" "$OUT"'
cat >"$HOME/login.sh" <<'LOGIN'
claude() { if [ "$1 $2" = "auth status" ]; then echo '{"loggedIn": true}'; else echo "claude was started"; fi; }
LOGIN
check "an existing login is skipped, with or without a terminal" 'python3 -I "$WORK/notty.py" "source \"$REPO_DIR/install.sh\"; source \"$HOME/login.sh\"; login_claude" >"$OUT" && grep -q "Already logged in." "$OUT"'

printf '\n4. Claude login and the macOS keychain\n'
# Simulated security command: $STATE/keychain is "ok", "none" (no default keychain), "missing" (the file is not there),
# or "locked" (the keychain cannot be read). It records every call; a keychain command that changes something is a failure.
cat >"$WORK/tools/security" <<'TOOL'
#!/bin/bash
printf 'security %s\n' "$*" >>"$CALLS"
mode="$(cat "$STATE/keychain")"
case "${1:-}" in
  default-keychain)
    if [ "$mode" = none ]; then echo "security: SecKeychainCopyDefault: A default keychain could not be found." >&2; exit 1; fi
    echo "    \"$HOME/Library/Keychains/login.keychain-db\""
    ;;
  show-keychain-info)
    if [ "$mode" = locked ]; then echo "security: SecKeychainCopySettings $2: User canceled the operation." >&2; exit 128; fi
    echo "Keychain \"$2\" lock-on-sleep timeout=300s"
    ;;
  *) echo "unexpected security call: $*" >&2; exit 99 ;;
esac
TOOL
chmod +x "$WORK/tools/security"
# keychain_setup <name> <mode> <claude mode>: claude mode "ok" logs in; "nosave" locks the keychain and prints the Claude Code
# keychain error, "fail" fails with another error.
keychain_setup() {
  setup "$1" ok
  cp "$WORK/tools/security" "$HOME/../bin/security"
  printf '%s\n' "$2" >"$STATE/keychain"
  if [ "$2" != none ] && [ "$2" != missing ]; then mkdir -p "$HOME/Library/Keychains"; fi
  if [ "$2" = ok ] || [ "$2" = locked ]; then : >"$HOME/Library/Keychains/login.keychain-db"; fi
  cat >"$HOME/../bin/claude" <<'TOOL'
#!/bin/bash
printf 'claude %s\n' "$*" >>"$CALLS"
if [ "$1 $2" = "auth status" ]; then
  if [ -e "$STATE/logged-in" ]; then echo '{"loggedIn": true}'; else echo '{"loggedIn": false}'; fi
  exit 0
fi
if [ "$(cat "$STATE/claude")" = nosave ]; then
  echo locked >"$STATE/keychain"
  echo "Couldn't log in: Couldn't save your login. If your Mac's keychain is locked, unlock it and log in again."
  exit 1
fi
if [ "$(cat "$STATE/claude")" = fail ]; then echo "Login failed."; exit 1; fi
touch "$STATE/logged-in"
echo "Login successful."
TOOL
  chmod +x "$HOME/../bin/claude"
  printf '%s\n' "${3:-ok}" >"$STATE/claude"
}
# login_in_terminal: step 13 with a pseudo terminal, with the result in $OUT.
login_in_terminal() {
  python3 -I "$WORK/pty.py" "source \"$REPO_DIR/install.sh\"; LOG_DIR=\"$HOME\"; login_claude; echo \"the installer continues\"" >"$OUT"
}

keychain_setup kc-ok ok
check "a usable keychain: the login runs and nothing changes" 'login_in_terminal; grep -q "Login successful." "$OUT" && grep -q "the installer continues" "$OUT" && ! grep -q "Stopped:" "$OUT"'
check "a usable keychain: only reads the keychain" '! grep "^security" "$CALLS" | grep -vqE "^security (default-keychain -d user|show-keychain-info )"'
keychain_setup kc-in ok
touch "$STATE/logged-in"
check "an existing login is skipped before any keychain check" 'login_in_terminal; grep -q "Already logged in." "$OUT" && ! grep -q "^security" "$CALLS"'
keychain_setup kc-none none
check "no default keychain (a home folder without Library/Keychains): stops before the browser login" 'login_in_terminal; grep -q "no usable default keychain" "$OUT" && grep -q "security default-keychain -s ~/Library/Keychains/login.keychain-db" "$OUT" && ! grep -q "^claude auth login" "$CALLS" && ! grep -q "the installer continues" "$OUT"'
check "no default keychain: the message warns about Reset To Defaults" 'grep -q "Never click \"Reset To Defaults\"" "$OUT"'
keychain_setup kc-missing missing
check "the default keychain file is missing: stops before the browser login" 'login_in_terminal; grep -q "no usable default keychain" "$OUT" && ! grep -q "^claude auth login" "$CALLS"'
keychain_setup kc-locked locked
check "a locked keychain: stops before the browser login with the unlock line" 'login_in_terminal; grep -q "keychain of this Mac is locked" "$OUT" && grep -q "security unlock-keychain ~/Library/Keychains/login.keychain-db" "$OUT" && ! grep -q "^claude auth login" "$CALLS"'
check "a locked keychain: the installer never changes a keychain" '! grep "^security" "$CALLS" | grep -qE "unlock-keychain|create-keychain|delete-keychain|default-keychain -s|reset"'
keychain_setup kc-nosave ok nosave
check "the keychain locks during the login: shows the keychain fix, not only \"did not complete\"" 'login_in_terminal; grep -q "Couldn.t save your login" "$OUT" && grep -q "keychain of this Mac is locked" "$OUT" && grep -q "security unlock-keychain" "$OUT" && grep -q "Never click \"Reset To Defaults\"" "$OUT" && ! grep -q "The Claude login did not complete" "$OUT"'
keychain_setup kc-other ok fail
check "another login failure still says the login did not complete" 'login_in_terminal; grep -q "The Claude login did not complete." "$OUT" && ! grep -q "Reset To Defaults" "$OUT"'

echo
if [ "$FAILURES" -ne 0 ]; then echo "$FAILURES check(s) failed."; exit 1; fi
echo "All checks passed."
