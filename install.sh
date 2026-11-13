#!/bin/bash
# Zeus installer for macOS.
# Installs the tools that Zeus needs and clones the private zeus repo.
# Each step is skipped when it is already done, so you can run it again safely.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/theo-henry/zeus-install/main/install.sh | bash
#
# Environment:
#   ZEUS_INSTALL_ACCEPT_ANACONDA_LICENSE=yes  accept the Anaconda license without a prompt.
#   ZEUS_INSTALL_SYSTEM_CONDA_DIRS="..."      folders outside the home folder to search for conda (for tests).
#   ZEUS_INSTALL_REPOS="owner/a owner/b"      replaces the list of private repos for the access check (for tests).
#   ZEUS_APP_URL=...                         replaces the download address of the Zeus app (for tests).
#   ZEUS_APP_DIR=...                         installs the Zeus app into this folder, not /Applications (for tests).
#   ZEUS_INSTALL_APP=1                        app mode, used by Zeus.app. It adds two steps (the Zeus skill plugins and
#                                             the Claude login) and prints machine-readable lines that start with
#                                             "@@zeus " so that the app can show a checklist. Terminal use is unchanged.
#
# Options:
#   --check   app mode only: report which steps are already done, then stop. Installs nothing.

# ShellCheck 0.11 reports SC2218 for helpers that are defined before main runs (0.10 does not).
# shellcheck disable=SC2218
set -euo pipefail

ZEUS_REPO="theo-henry/zeus"
ZEUS_DIR="$HOME/Code/zeus"
ZEUS_OWNER="Theo"
EDITOR_REPO="theo-henry/zeus-editor"
# Every private repo that Zeus uses. Step 5 checks access to all of them before anything is installed.
# Add a new repo here only. The workspace is $ZEUS_REPO. The others are the plugin marketplaces.
ZEUS_REPOS="$ZEUS_REPO $EDITOR_REPO theo-henry/YAML-builder theo-henry/celonis-ocpm theo-henry/celonis-pql"
EDITOR_PLUGIN="zeus-editor@zeus-editor"
EDITOR_MARKETPLACE="zeus-editor"

NODE_VERSION="24.21.0"
NODE_MIN_VERSION="18.20.5"
NODE_SHA256_ARM64="bed7eea5325e1108f32ce5228ddd6a5f0f08a499ee42aa7442aea583702f6057"
NODE_SHA256_X64="1462cb3b3046b815cf8ea436d3da450ec1a9f11dac7e5a46b0ada5305d7e8097"

# Anaconda stopped Intel Mac builds after 2025.06-1.
ANACONDA_ARM64="Anaconda3-2026.07-1-MacOSX-arm64.sh"
ANACONDA_SHA256_ARM64="6a9b63c645db4dbe293ffe9f168f7e380fe7a041fc863e67ee84db027425bce2"
ANACONDA_X86_64="Anaconda3-2025.06-1-MacOSX-x86_64.sh"
ANACONDA_SHA256_X86_64="58139fe195337f3041259e3a611339ed3afa4d164cc9aa2a7e8e84c0673e3670"
ANACONDA_LICENSE_URL="https://www.anaconda.com/legal/terms/terms-of-service"
PYTHON_MIN_VERSION="3.10"

LOCAL_BIN="$HOME/.local/bin"
NODE_DIR="$HOME/.local/node"
TOOLS_ENV="$HOME/.local/zeus-tools"
# The line is written to ~/.zprofile as it is, so it must not expand here.
# shellcheck disable=SC2016
PATH_LINE='export PATH="$HOME/.local/node/bin:$HOME/.local/bin:$PATH"'

LOG_DIR="$HOME/Library/Logs/zeus-install"
SUMMARY=()
WORK_DIR=""

# App mode (Zeus.app). The skill plugins are installed for the user, like the Zeus Editor plugin in step 10.
APP_MODE=""
if [ "${ZEUS_INSTALL_APP:-}" = "1" ]; then APP_MODE=1; fi
SKILL_PLUGINS="celonis-yaml-builder@yaml-builder:theo-henry/YAML-builder celonis-ocpm@celonis-ocpm:theo-henry/celonis-ocpm celonis-pql@celonis-pql:theo-henry/celonis-pql"
ZEUS_APP_URL="${ZEUS_APP_URL:-https://github.com/theo-henry/zeus-install/releases/latest/download/Zeus.zip}"
APP_INSTALLED=""
# Terminal use: step 12 installs the Zeus app. App mode: steps 12 and 13 finish the setup that the app needs.
TOTAL_STEPS=12
if [ -n "$APP_MODE" ]; then TOTAL_STEPS=13; fi
CURRENT_STEP=0

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }

# Prints one line for Zeus.app in app mode: "@@zeus <event> <step> <text>". Prints nothing in Terminal use.
emit() {
  # On stderr, so that a line from inside a command substitution, such as ask, is not captured.
  if [ -n "$APP_MODE" ]; then printf '@@zeus %s\n' "$*" >&2; fi
}

# step <number> <name>
step() {
  CURRENT_STEP="$1"
  printf '\n'
  bold "==> $1/$TOTAL_STEPS $2"
  emit "running $1 $2"
}

fail() {
  emit "failed $CURRENT_STEP $1"
  printf '\n\033[1;31mStopped:\033[0m %s\n' "$1" >&2
  shift
  local line
  for line in "$@"; do
    printf '    %s\n' "$line" >&2
  done
  if [ -n "$APP_MODE" ]; then
    printf '\n    When it is fixed, click Try again. Completed steps are skipped.\n' >&2
  else
    printf '\n    When it is fixed, run the same install line again. Completed steps are skipped.\n' >&2
  fi
  exit 1
}

record() {
  SUMMARY+=("$(printf '%-9s %s' "$1" "$2")")
  emit "$1 $CURRENT_STEP $2"
}

cleanup() {
  if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
    rm -rf "$WORK_DIR"
  fi
}

# Reads one answer from the keyboard, also when this script runs through "curl | bash".
ask() {
  local prompt="$1" answer
  if ! { exec 3</dev/tty; } 2>/dev/null; then
    fail "This step needs your answer, but no keyboard is connected." \
      "Run the install line in the Terminal app."
  fi
  emit "ask $CURRENT_STEP $prompt"
  printf '    %s ' "$prompt" >&2
  IFS= read -r answer <&3 || answer=""
  exec 3<&-
  printf '%s' "$answer"
}

# Runs a command with the keyboard as its input.
with_tty() {
  if ! { exec 3</dev/tty; } 2>/dev/null; then
    fail "This step needs the keyboard, but no keyboard is connected." \
      "Run the install line in the Terminal app."
  fi
  "$@" <&3
  local status=$?
  exec 3<&-
  return "$status"
}

# Returns success when version $1 is at least version $2.
version_at_least() {
  local IFS=.
  local -a have want
  read -r -a have <<<"$1"
  read -r -a want <<<"$2"
  local i h w
  for i in 0 1 2; do
    h="${have[i]:-0}"
    w="${want[i]:-0}"
    h="${h%%[!0-9]*}"
    w="${w%%[!0-9]*}"
    if ((10#${h:-0} > 10#${w:-0})); then return 0; fi
    if ((10#${h:-0} < 10#${w:-0})); then return 1; fi
  done
  return 0
}

download() {
  local url="$1" target="$2" sha256="$3"
  info "Downloading $(basename "$url")"
  curl -fL --progress-bar --retry 3 -o "$target" "$url" ||
    fail "The download of $(basename "$url") failed." "Check your internet connection."
  local actual
  actual="$(shasum -a 256 "$target" | awk '{print $1}')"
  if [ "$actual" != "$sha256" ]; then
    fail "The download of $(basename "$url") is damaged or changed (checksum mismatch)."
  fi
}

# Puts the home-folder tools first on PATH for the rest of this run.
use_local_path() {
  case ":$PATH:" in
    *":$NODE_DIR/bin:"*) ;;
    *) PATH="$NODE_DIR/bin:$PATH" ;;
  esac
  case ":$PATH:" in
    *":$LOCAL_BIN:"*) ;;
    *) PATH="$LOCAL_BIN:$PATH" ;;
  esac
  export PATH
}

# Saves the PATH line in ~/.zprofile for new Terminal windows. Called only after a step installs into ~/.local.
add_path_line() {
  local profile="$HOME/.zprofile"
  touch "$profile"
  if ! grep -qF "$PATH_LINE" "$profile"; then
    printf '\n# Added by the Zeus installer\n%s\n' "$PATH_LINE" >>"$profile"
  fi
  use_local_path
}

python_ok() {
  command -v python3 >/dev/null 2>&1 &&
    python3 -c "import sys; sys.exit(0 if sys.version_info >= (${PYTHON_MIN_VERSION/./, }) else 1)" 2>/dev/null
}

find_conda() {
  local candidate
  if candidate="$(command -v conda 2>/dev/null)" && [ -x "$candidate" ]; then
    printf '%s' "$candidate"
    return 0
  fi
  local system_dirs="${ZEUS_INSTALL_SYSTEM_CONDA_DIRS-/opt/anaconda3 /opt/miniconda3}"
  # shellcheck disable=SC2086 # system_dirs is a space-separated list.
  for candidate in "$HOME/anaconda3" "$HOME/miniconda3" "$HOME/miniforge3" $system_dirs; do
    if [ -x "$candidate/bin/conda" ]; then
      printf '%s' "$candidate/bin/conda"
      return 0
    fi
  done
  return 1
}

# Step 1 - Xcode Command Line Tools (git).
install_xcode_tools() {
  step 1 "Git (Xcode Command Line Tools)"
  local dev_dir
  if dev_dir="$(xcode-select -p 2>/dev/null)" && [ -x "$dev_dir/usr/bin/git" ]; then
    info "Already installed."
    record "skipped" "Git (Xcode Command Line Tools)"
    return
  fi
  info "A window opens. Click Install and accept the license."
  info "Your Mac password can be necessary. This can take 5 to 20 minutes."
  xcode-select --install >/dev/null 2>&1 || true
  local waited=0
  until dev_dir="$(xcode-select -p 2>/dev/null)" && [ -x "$dev_dir/usr/bin/git" ]; do
    if ((waited >= 3600)); then
      fail "The Xcode Command Line Tools are not installed after 60 minutes." \
        "Run 'xcode-select --install' yourself, finish the install, and try again."
    fi
    sleep 10
    waited=$((waited + 10))
  done
  info "Installed."
  record "done" "Git (Xcode Command Line Tools)"
}

# Step 2 - Anaconda (Python and conda).
install_anaconda() {
  step 2 "Python (Anaconda)"
  if find_conda >/dev/null; then
    info "conda is already installed."
    record "skipped" "Python (Anaconda)"
    return
  fi
  if python_ok && command -v gh >/dev/null 2>&1; then
    info "Python $PYTHON_MIN_VERSION or later and the GitHub CLI are already installed."
    record "skipped" "Python (Anaconda)"
    return
  fi

  local file sha256
  case "$(uname -m)" in
    arm64) file="$ANACONDA_ARM64"; sha256="$ANACONDA_SHA256_ARM64" ;;
    x86_64) file="$ANACONDA_X86_64"; sha256="$ANACONDA_SHA256_X86_64" ;;
    *) fail "This Mac type ($(uname -m)) is not supported." ;;
  esac

  if [ -e "$HOME/anaconda3" ]; then
    fail "The folder ~/anaconda3 exists, but it has no working conda." \
      "Move or delete ~/anaconda3, or ask $ZEUS_OWNER for help."
  fi

  info "Anaconda license: $ANACONDA_LICENSE_URL"
  local answer="${ZEUS_INSTALL_ACCEPT_ANACONDA_LICENSE:-}"
  if [ "$answer" != "yes" ]; then
    answer="$(ask "Do you accept the Anaconda license? (y/n)")"
  fi
  case "$answer" in
    y | Y | yes | YES | Yes) ;;
    *) fail "You did not accept the Anaconda license, so Anaconda is not installed." ;;
  esac

  info "The download is about 850 MB. This can take some minutes."
  download "https://repo.anaconda.com/archive/$file" "$WORK_DIR/$file" "$sha256"
  info "Installing Anaconda into ~/anaconda3"
  bash "$WORK_DIR/$file" -b -p "$HOME/anaconda3" >"$LOG_DIR/anaconda.log" 2>&1 ||
    fail "The Anaconda install failed." "See the log: $LOG_DIR/anaconda.log"
  rm -f "$WORK_DIR/$file"
  "$HOME/anaconda3/bin/conda" init zsh >/dev/null ||
    fail "'conda init zsh' failed."
  PATH="$HOME/anaconda3/bin:$PATH"
  export PATH
  info "Installed."
  record "done" "Python (Anaconda)"
}

# Step 3 - GitHub CLI from conda-forge, in its own environment.
install_gh() {
  step 3 "GitHub CLI"
  if command -v gh >/dev/null 2>&1; then
    info "Already installed."
    record "skipped" "GitHub CLI"
    return
  fi
  local conda
  conda="$(find_conda)" || fail "conda is not available, so the GitHub CLI cannot be installed."
  # Only conda-forge is used, so the Anaconda channel terms do not apply here.
  if [ ! -x "$TOOLS_ENV/bin/gh" ]; then
    info "Installing the GitHub CLI from conda-forge"
    "$conda" create -y -q -p "$TOOLS_ENV" --override-channels -c conda-forge gh >"$LOG_DIR/gh.log" 2>&1 ||
      fail "The GitHub CLI install failed." "See the log: $LOG_DIR/gh.log"
  fi
  mkdir -p "$LOCAL_BIN"
  ln -sf "$TOOLS_ENV/bin/gh" "$LOCAL_BIN/gh"
  add_path_line
  info "Installed."
  record "done" "GitHub CLI"
}

# Step 4 - Log in to GitHub.
login_github() {
  step 4 "GitHub login"
  if gh auth status -h github.com >/dev/null 2>&1; then
    info "Already logged in."
    record "skipped" "GitHub login"
  else
    info "Your browser opens. Enter the one-time code that is shown here."
    info "Log in with your GitHub password and 2FA."
    with_tty gh auth login -h github.com -p https -w ||
      fail "The GitHub login did not complete."
    record "done" "GitHub login"
  fi
  gh auth setup-git -h github.com ||
    fail "'gh auth setup-git' failed."
}

# Tells the user which private repos the account cannot reach, and who can fix it. Stops the install.
# Arguments: the user name, then the missing repos (owner/name).
fail_no_access() {
  local user="$1" repo
  shift
  local -a lines=("Your GitHub account '$user' has no access to these private repos:")
  for repo in "$@"; do
    lines+=("  - $repo")
  done
  lines+=("" "1. Check for invitations on GitHub and accept them:" "     https://github.com/notifications")
  for repo in "$@"; do
    lines+=("     https://github.com/$repo/invitations")
  done
  lines+=("2. If there is no invitation, send your GitHub username '$user' to $ZEUS_OWNER" "   and ask for access to the repos in the list.")
  fail "Your GitHub account has no access to all the private Zeus repos." "${lines[@]}"
}

# Step 5 - Check access to every private repo that Zeus uses. This only reads. Nothing is installed.
check_access() {
  step 5 "Access to the Zeus repos"
  local user repo
  local -a missing=()
  user="$(gh api user --jq .login 2>/dev/null)" || user="(unknown)"
  for repo in ${ZEUS_INSTALL_REPOS:-$ZEUS_REPOS}; do
    if gh api "repos/$repo" --silent >/dev/null 2>&1; then
      info "Access to $repo."
    else
      info "NO access to $repo."
      missing+=("$repo")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    fail_no_access "$user" "${missing[@]}"
  fi
  info "GitHub account '$user' has access to all the repos."
  record "done" "Access to the Zeus repos ($user)"
}

# Step 6 - Node.js in the home folder.
install_node() {
  step 6 "Node.js"
  local current=""
  if command -v node >/dev/null 2>&1; then
    current="$(node -p 'process.versions.node' 2>/dev/null || true)"
  fi
  if [ -n "$current" ] && version_at_least "$current" "$NODE_MIN_VERSION"; then
    info "Node.js $current is already installed."
    record "skipped" "Node.js ($current)"
    return
  fi

  local arch sha256
  case "$(uname -m)" in
    arm64) arch="arm64"; sha256="$NODE_SHA256_ARM64" ;;
    x86_64) arch="x64"; sha256="$NODE_SHA256_X64" ;;
    *) fail "This Mac type ($(uname -m)) is not supported." ;;
  esac
  local file="node-v$NODE_VERSION-darwin-$arch.tar.gz"
  download "https://nodejs.org/dist/v$NODE_VERSION/$file" "$WORK_DIR/$file" "$sha256"
  rm -rf "$NODE_DIR"
  mkdir -p "$NODE_DIR" "$LOCAL_BIN"
  tar -xzf "$WORK_DIR/$file" -C "$NODE_DIR" --strip-components=1 ||
    fail "Node.js could not be unpacked."
  add_path_line
  info "Installed Node.js $NODE_VERSION in ~/.local/node."
  record "done" "Node.js ($NODE_VERSION)"
}

# Step 7 - Claude Code.
install_claude() {
  step 7 "Claude Code"
  if command -v claude >/dev/null 2>&1 || [ -x "$LOCAL_BIN/claude" ]; then
    info "Already installed."
    record "skipped" "Claude Code"
    return
  fi
  curl -fsSL https://claude.ai/install.sh -o "$WORK_DIR/claude-install.sh" ||
    fail "The Claude Code installer could not be downloaded." "Check your internet connection."
  bash "$WORK_DIR/claude-install.sh" </dev/null ||
    fail "The Claude Code install failed."
  add_path_line
  command -v claude >/dev/null 2>&1 ||
    fail "Claude Code was installed, but the 'claude' command is not found."
  info "Installed."
  record "done" "Claude Code"
}

# Step 8 - Celonis content-cli.
install_content_cli() {
  step 8 "Celonis content-cli"
  if command -v content-cli >/dev/null 2>&1; then
    info "Already installed."
    record "skipped" "Celonis content-cli"
    return
  fi
  # npm hides parts of some paths in its output, so do not test its prefix folder here.
  if ! npm install -g @celonis/content-cli --no-fund --no-audit >"$LOG_DIR/content-cli.log" 2>&1; then
    if grep -q 'EACCES' "$LOG_DIR/content-cli.log"; then
      fail "npm cannot install global packages without sudo." \
        "Ask $ZEUS_OWNER for help. Do not use sudo." "See the log: $LOG_DIR/content-cli.log"
    fi
    fail "The content-cli install failed." "See the log: $LOG_DIR/content-cli.log"
  fi
  hash -r
  command -v content-cli >/dev/null 2>&1 ||
    fail "content-cli was installed, but the 'content-cli' command is not found."
  info "Installed."
  record "done" "Celonis content-cli"
}

# Step 9 - Clone the zeus repo.
# Brings an existing ~/Code/zeus clone up to date with the reviewed updater from origin/main
# (.claude/hooks/zeus_update.py --now): a fast-forward only, local work is never discarded, and when
# it cannot update it gives one step. An older origin/main without that updater keeps the clone as it is;
# the Zeus session start then updates it.
update_zeus() {
  local updater="$WORK_DIR/zeus_update.py" result outcome message step
  if ! git -C "$ZEUS_DIR" fetch --quiet origin main 2>/dev/null ||
    ! git -C "$ZEUS_DIR" show origin/main:.claude/hooks/zeus_update.py >"$updater" 2>/dev/null ||
    ! grep -q '^def now_cli' "$updater"; then
    info "Already cloned in ~/Code/zeus. Zeus updates itself when a Zeus session starts."
    record "skipped" "Zeus repo (~/Code/zeus)"
    return
  fi
  result="$( { python3 "$updater" --now --root "$ZEUS_DIR" 2>/dev/null || true; } | tail -n 1)"
  outcome="$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' 2>/dev/null || true)"
  case "$outcome" in
    current)
      # `current` means that this Zeus has what Zeus Editor needs; the clone can still be behind origin/main.
      if [ "$(git -C "$ZEUS_DIR" rev-list --count HEAD..origin/main 2>/dev/null || echo 1)" = 0 ]; then
        info "Already cloned in ~/Code/zeus, and up to date."
        record "skipped" "Zeus repo (~/Code/zeus, up to date)"
      else
        info "Already cloned in ~/Code/zeus, with the Zeus version that Zeus Editor needs."
        info "Zeus gets the newer updates when a Zeus session starts."
        record "skipped" "Zeus repo (~/Code/zeus)"
      fi
      ;;
    updated)
      info "Updated ~/Code/zeus to the reviewed version."
      record "done" "Zeus repo (~/Code/zeus, updated)"
      ;;
    *)
      message="$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("message",""))' 2>/dev/null || true)"
      step="$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("step",""))' 2>/dev/null || true)"
      info "${message:-Zeus in ~/Code/zeus could not update itself. Nothing was changed or discarded.}"
      info "To update: ${step:-run \`git pull --ff-only\` in ~/Code/zeus}."
      record "skipped" "Zeus repo (~/Code/zeus, not updated)"
      ;;
  esac
}

clone_zeus() {
  step 9 "Zeus repo"
  if [ -d "$ZEUS_DIR/.git" ]; then
    local remote
    remote="$(git -C "$ZEUS_DIR" remote get-url origin 2>/dev/null || true)"
    case "$remote" in
      *"$ZEUS_REPO"|*"$ZEUS_REPO.git")
        update_zeus
        return
        ;;
    esac
  fi
  if [ -e "$ZEUS_DIR" ]; then
    fail "The folder ~/Code/zeus exists, but it is not the zeus repo." \
      "Move or rename that folder, then run the same line again."
  fi
  mkdir -p "$(dirname "$ZEUS_DIR")"
  gh repo clone "$ZEUS_REPO" "$ZEUS_DIR" ||
    fail "The zeus repo could not be cloned."
  record "done" "Zeus repo (~/Code/zeus)"
}

# The shim for step 11. The quoted heredoc keeps every $ as it is.
write_zeus_shim() {
  cat <<'SHIM'
#!/bin/sh
# Starts Zeus through the newest installed zeus-editor plugin. Written by the Zeus installer.
newest=""
for candidate in "$HOME"/.claude/plugins/cache/*/zeus-editor/*/dist/zeus.mjs; do
  [ -f "$candidate" ] || continue
  if [ -z "$newest" ] || [ "$candidate" -nt "$newest" ]; then
    newest="$candidate"
  fi
done
if [ -z "$newest" ]; then
  echo "The Zeus Editor plugin is not installed. Run the Zeus install line again (see https://github.com/theo-henry/zeus-install)." >&2
  exit 1
fi
exec node "$newest" "$@"
SHIM
}

# Step 10 - The Zeus Editor plugin, for the current user (all folders).
# Step 5 already checked access to the private repo.
install_editor_plugin() {
  step 10 "Zeus Editor plugin"
  # Adding a marketplace that exists is safe. The update then fetches the newest version.
  claude plugin marketplace add "$EDITOR_REPO" --scope user </dev/null >"$LOG_DIR/zeus-editor.log" 2>&1 ||
    fail "The Zeus Editor marketplace could not be added." "See the log: $LOG_DIR/zeus-editor.log"
  claude plugin marketplace update "$EDITOR_MARKETPLACE" </dev/null >>"$LOG_DIR/zeus-editor.log" 2>&1 ||
    fail "The Zeus Editor marketplace could not be updated." "See the log: $LOG_DIR/zeus-editor.log"
  if claude plugin list </dev/null 2>/dev/null | grep -qF "$EDITOR_PLUGIN"; then
    claude plugin update "$EDITOR_PLUGIN" --scope user </dev/null >>"$LOG_DIR/zeus-editor.log" 2>&1 ||
      fail "The Zeus Editor plugin could not be updated." "See the log: $LOG_DIR/zeus-editor.log"
    info "Updated."
    record "done" "Zeus Editor plugin (updated)"
  else
    claude plugin install "$EDITOR_PLUGIN" --scope user </dev/null >>"$LOG_DIR/zeus-editor.log" 2>&1 ||
      fail "The Zeus Editor plugin could not be installed." "See the log: $LOG_DIR/zeus-editor.log"
    info "Installed."
    record "done" "Zeus Editor plugin"
  fi
}

# Step 11 - The zeus command.
install_zeus_command() {
  step 11 "The zeus command"
  local shim="$LOCAL_BIN/zeus" expected
  expected="$(write_zeus_shim)"
  if [ -x "$shim" ] && [ "$(cat "$shim")" = "$expected" ]; then
    info "Already installed."
    record "skipped" "The zeus command"
    return
  fi
  mkdir -p "$LOCAL_BIN"
  write_zeus_shim >"$shim"
  chmod +x "$shim"
  add_path_line
  info "Installed ~/.local/bin/zeus."
  record "done" "The zeus command"
}

# Step 12 (app mode) - The Zeus skill plugins, for the current user, like the Zeus Editor plugin.
# Step 5 already checked access to the private repos.
skill_plugin_installed() {
  claude plugin list </dev/null 2>/dev/null | grep -qF "$1"
}

install_skill_plugins() {
  step 12 "Zeus skill plugins"
  local entry plugin repo marketplace installed=0
  for entry in $SKILL_PLUGINS; do
    plugin="${entry%%:*}"
    repo="${entry#*:}"
    marketplace="${plugin#*@}"
    if skill_plugin_installed "$plugin"; then
      info "$plugin is already installed."
      continue
    fi
    info "Installing $plugin"
    claude plugin marketplace add "$repo" --scope user </dev/null >>"$LOG_DIR/skill-plugins.log" 2>&1 ||
      fail "The $marketplace marketplace could not be added." "See the log: $LOG_DIR/skill-plugins.log"
    claude plugin install "$plugin" --scope user </dev/null >>"$LOG_DIR/skill-plugins.log" 2>&1 ||
      fail "The $plugin plugin could not be installed." "See the log: $LOG_DIR/skill-plugins.log"
    installed=1
  done
  if [ "$installed" = 1 ]; then
    record "done" "Zeus skill plugins"
  else
    record "skipped" "Zeus skill plugins"
  fi
}

# Step 13 (app mode) - Log in to Claude.
claude_logged_in() {
  claude auth status </dev/null 2>/dev/null | grep -q '"loggedIn": *true'
}

login_claude() {
  step 13 "Claude login"
  if claude_logged_in; then
    info "Already logged in."
    record "skipped" "Claude login"
    return
  fi
  info "Your browser opens. Log in to Claude there."
  with_tty claude auth login ||
    fail "The Claude login did not complete."
  claude_logged_in || fail "The Claude login did not complete."
  record "done" "Claude login"
}

# --check (app mode): one "@@zeus state <step> ok|todo|always" line for each step. Installs nothing.
# "always" is a step that runs every time (the access check and the plugin update).
check_steps() {
  local dev_dir current
  state() { emit "state $1 $2"; }
  if dev_dir="$(xcode-select -p 2>/dev/null)" && [ -x "$dev_dir/usr/bin/git" ]; then state 1 ok; else state 1 todo; fi
  if find_conda >/dev/null || { python_ok && command -v gh >/dev/null 2>&1; }; then state 2 ok; else state 2 todo; fi
  if command -v gh >/dev/null 2>&1; then state 3 ok; else state 3 todo; fi
  if command -v gh >/dev/null 2>&1 && gh auth status -h github.com >/dev/null 2>&1; then state 4 ok; else state 4 todo; fi
  state 5 always
  current=""
  if command -v node >/dev/null 2>&1; then current="$(node -p 'process.versions.node' 2>/dev/null || true)"; fi
  if [ -n "$current" ] && version_at_least "$current" "$NODE_MIN_VERSION"; then state 6 ok; else state 6 todo; fi
  if command -v claude >/dev/null 2>&1 || [ -x "$LOCAL_BIN/claude" ]; then state 7 ok; else state 7 todo; fi
  if command -v content-cli >/dev/null 2>&1; then state 8 ok; else state 8 todo; fi
  if [ -d "$ZEUS_DIR/.git" ]; then state 9 ok; else state 9 todo; fi
  if command -v claude >/dev/null 2>&1 && skill_plugin_installed "$EDITOR_PLUGIN"; then state 10 ok; else state 10 todo; fi
  if [ -x "$LOCAL_BIN/zeus" ] && [ "$(cat "$LOCAL_BIN/zeus")" = "$(write_zeus_shim)" ]; then state 11 ok; else state 11 todo; fi
  local entry all=ok
  if command -v claude >/dev/null 2>&1; then
    for entry in $SKILL_PLUGINS; do
      skill_plugin_installed "${entry%%:*}" || all=todo
    done
  else
    all=todo
  fi
  state 12 "$all"
  if command -v claude >/dev/null 2>&1 && claude_logged_in; then state 13 ok; else state 13 todo; fi
  emit "checked"
}

# Step 12 (Terminal use) - The Zeus app. It opens Zeus without Terminal and finishes the setup
# (the skill plugins and the Claude login) in its own window. A failed download does not stop the
# installer: Zeus works without the app.
install_zeus_app() {
  step 12 "Zeus app"
  local target="${ZEUS_APP_DIR:-/Applications}"
  if [ ! -w "$target" ]; then
    target="$HOME/Applications"
    mkdir -p "$target"
  fi
  if ! curl -fsSL --retry 3 -o "$WORK_DIR/Zeus.zip" "$ZEUS_APP_URL" ||
    ! ditto -x -k "$WORK_DIR/Zeus.zip" "$WORK_DIR/zeus-app" ||
    ! codesign --verify --strict "$WORK_DIR/zeus-app/Zeus.app" 2>/dev/null; then
    info "The Zeus app could not be downloaded. Zeus works without it; use the steps below."
    record "failed" "Zeus app (not installed)"
    return
  fi
  if pgrep -f "$target/Zeus.app/Contents/MacOS/Zeus" >/dev/null 2>&1; then
    info "Quit the Zeus app, then run the same line again to update it."
    record "skipped" "Zeus app (open, not updated)"
    return
  fi
  rm -rf "$target/Zeus.app"
  ditto "$WORK_DIR/zeus-app/Zeus.app" "$target/Zeus.app"
  xattr -dr com.apple.quarantine "$target/Zeus.app" 2>/dev/null || true
  APP_INSTALLED="$target/Zeus.app"
  info "Installed $target/Zeus.app."
  record "done" "Zeus app"
}

print_summary() {
  if [ -n "$APP_MODE" ]; then
    emit "finished"
    printf '\n'
    bold "Zeus install is complete."
    return
  fi
  if [ -n "$APP_INSTALLED" ]; then
    printf '\n'
    bold "Zeus install is complete."
    local line
    for line in "${SUMMARY[@]}"; do
      info "$line"
    done
    printf '\n'
    bold "Next step"
    info "The Zeus app opens now. Follow its setup window: it installs the Zeus skill plugins,"
    info "logs you in to Claude, and keeps Zeus in the Dock. Then click Start Zeus."
    info "Later, click Zeus in the Dock to start Zeus. You do not need Terminal."
    printf '\n'
    open "$APP_INSTALLED" 2>/dev/null || true
    return
  fi
  printf '\n'
  bold "Zeus install is complete."
  local line
  for line in "${SUMMARY[@]}"; do
    info "$line"
  done
  printf '\n'
  bold "Next steps"
  info "1. Close this Terminal window and open a new one."
  info "2. Type: cd ~/Code/zeus"
  info "3. Type: claude   (log in to Claude in the browser the first time)"
  info "4. In Claude, type:"
  info "     /plugin install celonis-yaml-builder@yaml-builder"
  info "     /plugin install celonis-ocpm@celonis-ocpm"
  info "     /plugin install celonis-pql@celonis-pql"
  info "5. Close Claude (Ctrl + C two times), open a new Terminal window, then type: zeus"
  printf '\n'
}

main() {
  if [ "$(uname -s)" != "Darwin" ]; then
    fail "This installer works only on macOS."
  fi
  if [ "$(id -u)" -eq 0 ]; then
    fail "Do not run this installer with sudo." "Run the install line without sudo."
  fi

  mkdir -p "$LOG_DIR"
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/zeus-install.XXXXXX")"
  trap cleanup EXIT

  if [ "${1:-}" = "--check" ]; then
    [ -n "$APP_MODE" ] || fail "--check works only in app mode (ZEUS_INSTALL_APP=1)."
    use_local_path
    if [ -x "$HOME/anaconda3/bin/conda" ]; then PATH="$PATH:$HOME/anaconda3/bin"; export PATH; fi
    check_steps
    return
  fi

  bold "Zeus installer"
  info "This installs the tools for Zeus. Completed steps are skipped."

  # Tools that an earlier run installed in the home folder.
  use_local_path
  if [ -x "$HOME/anaconda3/bin/conda" ]; then
    PATH="$PATH:$HOME/anaconda3/bin"
    export PATH
  fi

  install_xcode_tools
  install_anaconda
  install_gh
  login_github
  check_access
  install_node
  install_claude
  install_content_cli
  clone_zeus
  install_editor_plugin
  install_zeus_command
  if [ -n "$APP_MODE" ]; then
    install_skill_plugins
    login_claude
  else
    install_zeus_app
  fi
  print_summary
}

# main is called on the last line, so bash has read the full script before it runs.
main "$@"
