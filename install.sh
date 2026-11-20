#!/bin/bash
# Zeus installer for macOS.
# Installs the tools that Zeus needs and clones the private zeus repo.
# Each step is skipped when it is already done, so you can run it again safely. An installed Claude Code is updated.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/theo-henry/zeus-install/main/install.sh | bash
#
# Environment:
#   ZEUS_INSTALL_ACCEPT_ANACONDA_LICENSE=yes  accept the Anaconda license without a prompt.
#   ZEUS_INSTALL_SYSTEM_CONDA_DIRS="..."      folders outside the home folder to search for conda (for tests).
#   ZEUS_INSTALL_REPOS="owner/a owner/b"      replaces the list of private repos for the access check (for tests).
#   ZEUS_APP_REPO="owner/name"               replaces the private repo with the Zeus app releases (for tests).
#   ZEUS_APP_DIR=...                         installs the Zeus app into this folder, not /Applications (for tests).
#   ZEUS_APP_NO_OPEN=1                       installs the Zeus app but does not open it (for tests).
#   ZEUS_APP_OPEN_ENV="NAME ..."             gives these environment variables (such as HOME) to the Zeus app that the
#                                             installer opens (for tests). ZEUS_APP_TEST_BACKGROUND=1 opens it behind
#                                             the other apps.
#   ZEUS_INSTALL_CLAUDE_UPDATE_TIMEOUT=300    stops the update of an installed Claude Code after this many seconds.
#   ZEUS_INSTALL_APP=1                        app mode, used by Zeus.app. It adds two steps (the Zeus skill plugins and
#                                             the Claude login) and prints machine-readable lines that start with
#                                             "@@zeus " so that the app can show a checklist. Terminal use is unchanged.
#
# EU mode (Claude on Google Vertex AI in the EU) gets the same three steps on every Mac: the Google Cloud CLI in
# ~/google-cloud-sdk, the EU workspace ~/Code/zeus-eu, and the Zeus plugins in the EU Claude Code folder ~/.zeus/eu/claude.
# No shell profile changes for EU mode. Each user then signs in to Google once (the Zeus app shows the button), and the
# Zeus maintainer gives the user's Google account two roles on the EU project: Vertex AI User (roles/aiplatform.user) and
# Service Usage Consumer (roles/serviceusage.serviceUsageConsumer), which the quota project of the sign-in needs.
#
# Options:
#   --check      app mode only: report which steps are already done, then stop. Installs nothing.
#   --app-only   used by install-app.sh: steps 1 to 5 (GitHub login and access check), then the Zeus app.
#                The app does the other steps in its setup window.
#   --eu-status-line  used by the Zeus app before each EU session: EU gets the status line of Standard again
#                (eu_mirror_status_line). Installs nothing else.

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

# EU mode. The values of the EU launch profile of Zeus Editor (eu-profile.json): `zeus --eu` uses these folders.
EU_WORKSPACE="$HOME/Code/zeus-eu"
EU_CONFIG_DIR="$HOME/.zeus/eu/claude"
# The Google Cloud CLI for the EU sign-in: the official macOS archive, pinned by version and checksum. gcloud updates
# itself later (gcloud components update) when the user wants.
GCLOUD_VERSION="593.0.0"
GCLOUD_SHA256_ARM64="3351dba1dbed21be0bc77c47462d6ba5d28a25ecc31e878ab1c0f32cc442741b"
GCLOUD_SHA256_X86_64="18b34987c1288c0c9c8ace5088d124e2a1b51eea7b7c645e2dae9d5832faa619"
GCLOUD_DIR="$HOME/google-cloud-sdk"

LOCAL_BIN="$HOME/.local/bin"
NODE_DIR="$HOME/.local/node"
TOOLS_ENV="$HOME/.local/zeus-tools"
# Where content-cli goes when the global folder of npm is not writable.
NPM_USER_PREFIX="$HOME/.npm-global"
# The line is written to ~/.zprofile as it is, so it must not expand here.
# shellcheck disable=SC2016
PATH_LINE='export PATH="$HOME/.local/node/bin:$HOME/.local/bin:$PATH"'

LOG_DIR="$HOME/Library/Logs/zeus-install"
SUMMARY=()
WORK_DIR=""
# The name of the EU step that runs (eu_step): a failure there is a warning, not the end of the setup.
EU_STEP=""
EU_STEP_REPORTED=""

# App mode (Zeus.app). The skill plugins are installed for the user, like the Zeus Editor plugin in step 10.
APP_MODE=""
if [ "${ZEUS_INSTALL_APP:-}" = "1" ]; then APP_MODE=1; fi
SKILL_PLUGINS="celonis-yaml-builder@yaml-builder:theo-henry/YAML-builder celonis-ocpm@celonis-ocpm:theo-henry/celonis-ocpm celonis-pql@celonis-pql:theo-henry/celonis-pql"
# The Zeus app comes from a release of the private zeus repo, so only an account with access can download it.
# App releases have tags "app-v<version>" (see app/release.sh); other releases of the repo are not used.
ZEUS_APP_REPO="${ZEUS_APP_REPO:-$ZEUS_REPO}"
APP_BUNDLE_ID="io.github.theo-henry.zeus"
APP_ONLY=""
if [ "${1:-}" = "--app-only" ]; then APP_ONLY=1; fi
# Terminal use: steps 12 to 14 set up EU mode, and step 15 installs the Zeus app. App mode: steps 12 and 13 finish the
# setup that the app needs, and steps 14 to 16 set up EU mode.
# --app-only: step 6 installs the Zeus app, and the app does steps 6 to 16 in its setup window.
TOTAL_STEPS=15
EU_FIRST_STEP=12
if [ -n "$APP_MODE" ]; then TOTAL_STEPS=16; EU_FIRST_STEP=14; fi
if [ -n "$APP_ONLY" ]; then TOTAL_STEPS=6; fi
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
  local line
  if [ -n "$EU_STEP" ]; then
    printf '\n\033[1;33mWarning:\033[0m %s\n' "$1" >&2
    shift
    for line in "$@"; do
      printf '    %s\n' "$line" >&2
    done
    printf '\n    EU mode is not ready on this Mac; the Zeus app tells what is missing. The setup goes on.\n' >&2
    printf '    To set up EU mode later, run the setup again. Completed steps are skipped.\n' >&2
    EU_STEP_REPORTED=1
    exit 1
  fi
  printf '\n\033[1;31mStopped:\033[0m %s\n' "$1" >&2
  shift
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

# Prints the device of the terminal of this script, such as /dev/ttys003. A program that reads "/dev/tty" as its
# input can fail: Claude Code (Bun) stops with "EINVAL: invalid argument, kqueue" on it, but it works with the real
# device. It falls back to /dev/tty when the device name is not known.
keyboard_device() {
  local name
  name="$(ps -o tty= -p $$ 2>/dev/null | tr -d ' ')"
  case "$name" in
    ttys[0-9]*) if [ -c "/dev/$name" ]; then printf '/dev/%s' "$name"; return; fi ;;
  esac
  printf '/dev/tty'
}

# Runs a command with the keyboard as its input.
with_tty() {
  local device
  if ! { exec 3</dev/tty; } 2>/dev/null; then
    fail "This step needs the keyboard, but no keyboard is connected." \
      "Run the install line in the Terminal app."
  fi
  device="$(keyboard_device)"
  if [ "$device" != "/dev/tty" ]; then
    exec 3<&-
    if ! { exec 3<"$device"; } 2>/dev/null; then exec 3</dev/tty; fi
  fi
  "$@" <&3
  local status=$?
  exec 3<&-
  return "$status"
}

# Stops with one exact command when a folder of the user belongs to another user (usually root, after an earlier
# install with sudo). The installer never runs sudo itself. A missing folder is fine: the tools create it.
# Arguments: the folders to check, as paths.
require_owned() {
  local dir bad=() owner
  for dir in "$@"; do
    [ -e "$dir" ] || continue
    owner="$(stat -L -f %u "$dir" 2>/dev/null || true)"
    if [ -n "$owner" ] && [ "$owner" != "$(id -u)" ]; then bad+=("$dir"); fi
  done
  [ "${#bad[@]}" -gt 0 ] || return 0
  stop_not_owned "${bad[@]}"
}

# Stops with one exact "sudo chown" line for folders that belong to another user.
# Arguments: the folders, as paths.
stop_not_owned() {
  local dir line="sudo chown -R \$(whoami)" shown=()
  for dir in "$@"; do
    shown+=("${dir/#$HOME/~}")
  done
  line="$line ${shown[*]}"
  fail "These folders belong to another user, so the tools cannot save their settings there: ${shown[*]}" \
    "Run this line in the Terminal app. It asks for your Mac password:" \
    "" "$line" ""
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

# Prints the real path of file $1: each symbolic link is followed, also on macOS versions without readlink -f.
real_path() {
  local path="$1" link dir real hops=0
  while link="$(readlink "$path" 2>/dev/null)" && [ "$hops" -lt 40 ]; do
    case "$link" in
      /*) path="$link" ;;
      *) path="$(dirname "$path")/$link" ;;
    esac
    hops=$((hops + 1))
  done
  dir="$(dirname "$path")"
  if real="$(cd "$dir" 2>/dev/null && pwd -P)"; then dir="$real"; fi
  printf '%s/%s' "$dir" "$(basename "$path")"
}

# Prints the process IDs of the process tree under $1 (children first, then $1).
process_tree() {
  local child
  for child in $(pgrep -P "$1" 2>/dev/null || true); do
    process_tree "$child"
  done
  printf '%s\n' "$1"
}

# run_with_timeout <seconds> <command...>: runs the command; after <seconds>, it stops the command and all its
# child processes and returns 124. macOS has no timeout command.
run_with_timeout() {
  local seconds="$1" pid watcher target expired status=0
  shift
  expired="$(mktemp "${TMPDIR:-/tmp}/zeus-timeout.XXXXXX")"
  rm -f "$expired"
  "$@" &
  pid=$!
  (
    sleep "$seconds" &
    wait $! || exit 0
    : >"$expired"
    for target in $(process_tree "$pid"); do kill -TERM "$target" 2>/dev/null || true; done
    sleep 2
    for target in $(process_tree "$pid"); do kill -KILL "$target" 2>/dev/null || true; done
  ) 2>/dev/null &
  watcher=$!
  wait "$pid" || status=$?
  if [ -e "$expired" ]; then
    # The watcher stops the remaining child processes, then ends.
    wait "$watcher" 2>/dev/null || true
    rm -f "$expired"
    return 124
  fi
  # Stops the watcher and its sleep, so that no process stays after the command.
  for target in $(process_tree "$watcher"); do kill -TERM "$target" 2>/dev/null || true; done
  wait "$watcher" 2>/dev/null || true
  rm -f "$expired"
  return "$status"
}

# Prints the version of the claude command $1, such as 2.1.3, or nothing.
claude_version() {
  local output
  output="$(run_with_timeout 30 "$1" --version </dev/null 2>/dev/null || true)"
  printf '%s' "$output" | head -n 1 | grep -oE '^[0-9]+(\.[0-9]+)+' || true
}

# Sets CLAUDE_UPDATE (a command) and CLAUDE_METHOD (a name for the user) to update the Claude Code of the claude
# command $1 with the method that installed it. The method comes from the real path of the command:
#   Homebrew   .../Caskroom/<cask>/...                                 brew upgrade --cask <cask>
#   npm        <prefix>/lib/node_modules/@anthropic-ai/claude-code/... npm install -g in the same prefix
#   other      the native install (~/.local/share/claude) and the local npm install (~/.claude/local)
#              claude update, which updates them in their own folder
CLAUDE_UPDATE=()
CLAUDE_METHOD=""
claude_update_method() {
  local command="$1" resolved prefix cask brew npm
  resolved="$(real_path "$command")"
  case "$resolved" in
    */Caskroom/*/*)
      cask="${resolved#*/Caskroom/}"
      cask="${cask%%/*}"
      brew="${resolved%%/Caskroom/*}/bin/brew"
      [ -x "$brew" ] || brew="brew"
      CLAUDE_UPDATE=("$brew" upgrade --cask "$cask")
      CLAUDE_METHOD="Homebrew"
      ;;
    */lib/node_modules/@anthropic-ai/claude-code/*)
      prefix="${resolved%%/lib/node_modules/@anthropic-ai/claude-code/*}"
      npm="$prefix/bin/npm"
      [ -x "$npm" ] || npm="npm"
      CLAUDE_UPDATE=("$npm" install -g --prefix "$prefix" --allow-scripts=@anthropic-ai/claude-code --no-fund --no-audit "@anthropic-ai/claude-code@latest")
      CLAUDE_METHOD="npm"
      ;;
    *)
      CLAUDE_UPDATE=("$command" update)
      CLAUDE_METHOD="claude update"
      ;;
  esac
}

# Updates an installed Claude Code to the newest version, with the method that installed it. It does not use
# sudo. A failed update does not stop the installer: Zeus works with the installed version.
update_claude() {
  local command before after status=0
  local seconds="${ZEUS_INSTALL_CLAUDE_UPDATE_TIMEOUT:-300}"
  command="$(command -v claude 2>/dev/null || printf '%s' "$LOCAL_BIN/claude")"
  before="$(claude_version "$command")"
  claude_update_method "$command"
  info "Claude Code ${before:-(unknown version)} is installed. Updating it with $CLAUDE_METHOD."
  run_with_timeout "$seconds" "${CLAUDE_UPDATE[@]}" </dev/null >"$LOG_DIR/claude-update.log" 2>&1 || status=$?
  after="$(claude_version "$command")"
  if [ "$status" -eq 0 ] && [ -n "$before" ] && [ -z "$after" ]; then
    status=1
    info "Warning: Claude Code does not run after the update."
  fi
  if [ "$status" -ne 0 ]; then
    if [ "$status" -eq 124 ]; then
      info "Warning: the update of Claude Code did not finish in $seconds seconds, so it was stopped."
    elif grep -q 'EACCES' "$LOG_DIR/claude-update.log"; then
      info "Warning: Claude Code could not be updated without sudo. Do not use sudo; ask $ZEUS_OWNER for help."
    else
      info "Warning: Claude Code could not be updated."
    fi
    info "Zeus works with the installed version ${after:-${before:-(unknown)}}. See the log: $LOG_DIR/claude-update.log"
    info "To update it later, run: ${CLAUDE_UPDATE[*]}"
    record "skipped" "Claude Code (${after:-${before:-unknown version}}, not updated)"
  elif [ -n "$after" ] && [ "$after" != "$before" ]; then
    info "Updated Claude Code from ${before:-an unknown version} to $after."
    record "done" "Claude Code (updated from ${before:-an unknown version} to $after)"
  else
    info "Claude Code is up to date (${after:-unknown version})."
    record "skipped" "Claude Code (up to date, ${after:-unknown version})"
  fi
}

# Step 7 - Claude Code. An installed Claude Code is updated.
install_claude() {
  step 7 "Claude Code"
  if command -v claude >/dev/null 2>&1 || [ -x "$LOCAL_BIN/claude" ]; then
    update_claude
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

# Installs content-cli with npm and adds the output to the log. Arguments: more npm options.
# Stops with the exact "sudo chown" line when the npm cache has files of another user (after an earlier sudo npm).
npm_install_content_cli() {
  npm install -g "$@" @celonis/content-cli --no-fund --no-audit >>"$LOG_DIR/content-cli.log" 2>&1 && return 0
  if grep -q 'cache folder contains root-owned files' "$LOG_DIR/content-cli.log"; then
    stop_not_owned "$HOME/.npm"
  fi
  return 1
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
  : >"$LOG_DIR/content-cli.log"
  if ! npm_install_content_cli; then
    if ! grep -q 'EACCES' "$LOG_DIR/content-cli.log"; then
      fail "The content-cli install failed." "See the log: $LOG_DIR/content-cli.log"
    fi
    # The global folder of npm (for example /usr/local) is not writable. Without sudo, install into a folder of
    # the user and link the command into ~/.local/bin, which is on PATH for this run and in ~/.zprofile.
    info "The global folder of npm is not writable. Installing content-cli in $NPM_USER_PREFIX instead."
    mkdir -p "$NPM_USER_PREFIX" "$LOCAL_BIN" ||
      fail "The folder $NPM_USER_PREFIX could not be created."
    npm_install_content_cli --prefix "$NPM_USER_PREFIX" ||
      fail "The content-cli install failed." "See the log: $LOG_DIR/content-cli.log"
    [ -x "$NPM_USER_PREFIX/bin/content-cli" ] ||
      fail "content-cli was installed, but the command file is missing." "See the log: $LOG_DIR/content-cli.log"
    ln -sf "$NPM_USER_PREFIX/bin/content-cli" "$LOCAL_BIN/content-cli"
    add_path_line
  fi
  hash -r
  command -v content-cli >/dev/null 2>&1 ||
    fail "content-cli was installed, but the 'content-cli' command is not found."
  info "Installed."
  record "done" "Celonis content-cli"
}

# Step 9 - Clone the zeus repo.
# Brings an existing clone up to date with the reviewed updater from origin/main
# (.claude/hooks/zeus_update.py --now): a fast-forward only, local work is never discarded, and when
# it cannot update it gives one step. An older origin/main without that updater keeps the clone as it is;
# the Zeus session start then updates it.
# update_workspace <folder> <name for the user>
update_workspace() {
  local dir="$1" label="$2" updater="$WORK_DIR/zeus_update.py" result outcome message step
  if ! git -C "$dir" fetch --quiet origin main 2>/dev/null ||
    ! git -C "$dir" show origin/main:.claude/hooks/zeus_update.py >"$updater" 2>/dev/null ||
    ! grep -q '^def now_cli' "$updater"; then
    info "Already cloned in $label. Zeus updates itself when a Zeus session starts."
    record "skipped" "Zeus repo ($label)"
    return
  fi
  result="$( { python3 "$updater" --now --root "$dir" 2>/dev/null || true; } | tail -n 1)"
  outcome="$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' 2>/dev/null || true)"
  case "$outcome" in
    current)
      # `current` means that this Zeus has what Zeus Editor needs; the clone can still be behind origin/main.
      if [ "$(git -C "$dir" rev-list --count HEAD..origin/main 2>/dev/null || echo 1)" = 0 ]; then
        info "Already cloned in $label, and up to date."
        record "skipped" "Zeus repo ($label, up to date)"
      else
        info "Already cloned in $label, with the Zeus version that Zeus Editor needs."
        info "Zeus gets the newer updates when a Zeus session starts."
        record "skipped" "Zeus repo ($label)"
      fi
      ;;
    updated)
      info "Updated $label to the reviewed version."
      record "done" "Zeus repo ($label, updated)"
      ;;
    *)
      message="$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("message",""))' 2>/dev/null || true)"
      step="$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("step",""))' 2>/dev/null || true)"
      info "${message:-Zeus in $label could not update itself. Nothing was changed or discarded.}"
      info "To update: ${step:-run \`git pull --ff-only\` in $label}."
      record "skipped" "Zeus repo ($label, not updated)"
      ;;
  esac
}

# clone_workspace <folder> <name for the user>: clones the zeus repo there, or updates the clone that is there.
clone_workspace() {
  local dir="$1" label="$2"
  if [ -d "$dir/.git" ]; then
    local remote
    remote="$(git -C "$dir" remote get-url origin 2>/dev/null || true)"
    case "$remote" in
      *"$ZEUS_REPO"|*"$ZEUS_REPO.git")
        update_workspace "$dir" "$label"
        return
        ;;
    esac
  fi
  if [ -e "$dir" ]; then
    fail "The folder $label exists, but it is not the zeus repo." \
      "Move or rename that folder, then run the same line again."
  fi
  mkdir -p "$(dirname "$dir")"
  gh repo clone "$ZEUS_REPO" "$dir" ||
    fail "The zeus repo could not be cloned into $label."
  record "done" "Zeus repo ($label)"
}

clone_zeus() {
  step 9 "Zeus repo"
  # shellcheck disable=SC2088 # A name for the user, not a path.
  clone_workspace "$ZEUS_DIR" "~/Code/zeus"
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

# EU mode, steps 12 to 14 (terminal use) or 14 to 16 (app mode). The same on every Mac; no shell profile changes.

# Prints the first gcloud in the places where Zeus Editor's EU check looks (src/eu/preflight.js): PATH, then the usual
# install folders.
find_gcloud() {
  local candidate
  if candidate="$(command -v gcloud 2>/dev/null)" && [ -x "$candidate" ]; then
    printf '%s' "$candidate"
    return 0
  fi
  for candidate in "$GCLOUD_DIR/bin/gcloud" /opt/homebrew/bin/gcloud /opt/homebrew/share/google-cloud-sdk/bin/gcloud \
    /usr/local/bin/gcloud /usr/local/share/google-cloud-sdk/bin/gcloud; do
    if [ -x "$candidate" ] && [ -f "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

# Step 12/14 - The Google Cloud CLI, for the Google sign-in of EU mode. Claude Code itself reads the sign-in file.
install_gcloud() {
  step "$EU_FIRST_STEP" "Google Cloud CLI (EU mode)"
  local found
  if found="$(find_gcloud)"; then
    info "Already installed ($found)."
    record "skipped" "Google Cloud CLI"
    return
  fi
  if [ -e "$GCLOUD_DIR" ]; then
    fail "The folder ~/google-cloud-sdk exists, but it has no gcloud command." \
      "Move or rename that folder, then run the same line again."
  fi
  local arch sha256
  case "$(uname -m)" in
    arm64) arch="arm"; sha256="$GCLOUD_SHA256_ARM64" ;;
    x86_64) arch="x86_64"; sha256="$GCLOUD_SHA256_X86_64" ;;
    *) fail "This Mac type ($(uname -m)) is not supported." ;;
  esac
  local file="google-cloud-cli-$GCLOUD_VERSION-darwin-$arch.tar.gz"
  download "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/$file" "$WORK_DIR/$file" "$sha256"
  mkdir -p "$WORK_DIR/gcloud"
  tar -xzf "$WORK_DIR/$file" -C "$WORK_DIR/gcloud" && [ -x "$WORK_DIR/gcloud/google-cloud-sdk/bin/gcloud" ] ||
    fail "The Google Cloud CLI could not be unpacked."
  mv "$WORK_DIR/gcloud/google-cloud-sdk" "$GCLOUD_DIR" ||
    fail "The Google Cloud CLI could not be moved to ~/google-cloud-sdk."
  # No usage reports to Google, for this install only (not the user's own gcloud settings).
  "$GCLOUD_DIR/bin/gcloud" config set core/disable_usage_reporting true --installation </dev/null >/dev/null 2>&1 || true
  if ! "$GCLOUD_DIR/bin/gcloud" --version </dev/null >"$LOG_DIR/gcloud.log" 2>&1; then
    fail "The Google Cloud CLI was installed in ~/google-cloud-sdk, but it does not run." \
      "It needs Python 3.10 or later, which step 2 installs." "See the log: $LOG_DIR/gcloud.log"
  fi
  info "Installed in ~/google-cloud-sdk. Your shell profile does not change: Zeus finds gcloud there."
  record "done" "Google Cloud CLI"
}

# Step 13/15 - The EU workspace: a second clone of the zeus repo, for EU mode only.
clone_eu_workspace() {
  step $((EU_FIRST_STEP + 1)) "EU workspace"
  # shellcheck disable=SC2088 # A name for the user, not a path.
  clone_workspace "$EU_WORKSPACE" "~/Code/zeus-eu"
}

# Runs claude with the EU Claude Code folder.
eu_claude() {
  CLAUDE_CONFIG_DIR="$EU_CONFIG_DIR" claude "$@" </dev/null
}

# All Zeus plugins (the Zeus Editor and the skill plugins), as "plugin@marketplace:owner/repo".
eu_plugin_entries() {
  printf '%s\n' "$EDITOR_PLUGIN:$EDITOR_REPO"
  # shellcheck disable=SC2086 # SKILL_PLUGINS is a space-separated list.
  printf '%s\n' $SKILL_PLUGINS
}

eu_plugins_installed() {
  local list entry
  list="$(eu_claude plugin list 2>/dev/null)" || return 1
  while IFS= read -r entry; do
    printf '%s' "$list" | grep -qF "${entry%%:*}" || return 1
  done < <(eu_plugin_entries)
}

# The first start of Claude Code in the EU folder asks for a theme and for trust in the EU workspace, which the Zeus app
# can not answer. The installer answers them as the Standard Claude Code of this Mac did: the same theme, and trust for
# the EU workspace, which is the same zeus repo as ~/Code/zeus. Imports of files outside the workspace stay off.
eu_first_start_settings() {
  python3 - "$EU_CONFIG_DIR/.claude.json" "$HOME/.claude.json" "$EU_WORKSPACE" <<'PY'
import json, os, sys, tempfile
target, standard, workspace = sys.argv[1], sys.argv[2], os.path.realpath(sys.argv[3])
def read(path):
    try:
        with open(path, encoding="utf-8") as handle:
            value = json.load(handle)
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}
config, theme = read(target), read(standard).get("theme")
config["hasCompletedOnboarding"] = True
if isinstance(theme, str) and theme and "theme" not in config:
    config["theme"] = theme
projects = config.setdefault("projects", {})
entry = projects.setdefault(workspace, {})
entry["hasTrustDialogAccepted"] = True
entry.setdefault("hasClaudeMdExternalIncludesApproved", False)
entry["hasClaudeMdExternalIncludesWarningShown"] = True
os.makedirs(os.path.dirname(target), mode=0o700, exist_ok=True)
handle, temporary = tempfile.mkstemp(dir=os.path.dirname(target), prefix=".claude.json.")
with os.fdopen(handle, "w", encoding="utf-8") as out:
    json.dump(config, out, indent=2)
os.replace(temporary, target)
PY
}

eu_first_start_done() {
  python3 - "$EU_CONFIG_DIR/.claude.json" "$EU_WORKSPACE" <<'PY' 2>/dev/null
import json, os, sys
try:
    config = json.load(open(sys.argv[1], encoding="utf-8"))
    entry = config["projects"][os.path.realpath(sys.argv[2])]
    sys.exit(0 if config.get("hasCompletedOnboarding") is True and entry.get("hasTrustDialogAccepted") is True
             and entry.get("hasClaudeMdExternalIncludesWarningShown") is True else 1)
except Exception:
    sys.exit(1)
PY
}

# EU Claude Code reads settings.json of the EU folder only. EU follows the status line of Standard Claude Code of this
# Mac, so the two modes look the same. Zeus does not install a status line itself. zeus-status-line.json in the EU folder
# keeps the value that Zeus last copied. While the EU status line is not set or still has that value, each run copies the
# Standard one again, or removes it when Standard has none. An EU status line that the user set stays as it is.
# Each install runs it, and the Zeus app runs it before each EU session (install.sh --eu-status-line).
eu_mirror_status_line() {
  python3 - "$EU_CONFIG_DIR/settings.json" "$EU_CONFIG_DIR/zeus-status-line.json" "$HOME/.claude/settings.json" <<'PY'
import json, os, sys, tempfile
target, record, standard = sys.argv[1], sys.argv[2], sys.argv[3]
def read(path):
    try:
        with open(path, encoding="utf-8") as handle:
            value = json.load(handle)
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}
def write(path, value):
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    handle, temporary = tempfile.mkstemp(dir=os.path.dirname(path), prefix="." + os.path.basename(path) + ".")
    with os.fdopen(handle, "w", encoding="utf-8") as out:
        json.dump(value, out, indent=2)
    os.replace(temporary, path)
line = read(standard).get("statusLine")
settings, mirrored = read(target), read(record).get("statusLine")
if "statusLine" in settings and settings["statusLine"] != mirrored:
    sys.exit(0)
if isinstance(line, dict):
    if settings.get("statusLine") != line:
        settings["statusLine"] = line
        write(target, settings)
    if mirrored != line:
        write(record, {"statusLine": line})
    sys.exit(0)
if "statusLine" in settings:
    del settings["statusLine"]
    write(target, settings)
if os.path.exists(record):
    os.remove(record)
PY
}

# Step 14/16 - The Zeus plugins in the EU Claude Code folder. EU Claude Code reads its plugins, settings, and chats there
# only, never from ~/.claude. Each run updates them, as step 10 does for Standard.
install_eu_plugins() {
  step $((EU_FIRST_STEP + 2)) "Zeus plugins of EU mode"
  mkdir -p "$EU_CONFIG_DIR"
  chmod 700 "$HOME/.zeus/eu" "$EU_CONFIG_DIR" 2>/dev/null || true
  local entry plugin repo marketplace log="$LOG_DIR/eu-plugins.log"
  : >"$log"
  while IFS= read -r entry; do
    plugin="${entry%%:*}"
    repo="${entry#*:}"
    marketplace="${plugin#*@}"
    eu_claude plugin marketplace add "$repo" --scope user >>"$log" 2>&1 ||
      fail "The $marketplace marketplace could not be added for EU mode." "See the log: $log"
    eu_claude plugin marketplace update "$marketplace" >>"$log" 2>&1 ||
      fail "The $marketplace marketplace could not be updated for EU mode." "See the log: $log"
    if eu_claude plugin list 2>/dev/null | grep -qF "$plugin"; then
      eu_claude plugin update "$plugin" --scope user >>"$log" 2>&1 ||
        fail "The $plugin plugin could not be updated for EU mode." "See the log: $log"
    else
      info "Installing $plugin"
      eu_claude plugin install "$plugin" --scope user >>"$log" 2>&1 ||
        fail "The $plugin plugin could not be installed for EU mode." "See the log: $log"
    fi
  done < <(eu_plugin_entries)
  eu_first_start_settings || fail "The first-start settings of EU mode could not be written in ~/.zeus/eu/claude."
  eu_mirror_status_line || fail "The status line of EU mode could not be written in ~/.zeus/eu/claude."
  info "Installed in ~/.zeus/eu/claude."
  info "For EU mode, sign in to Google once in the Zeus app, and ask $ZEUS_OWNER for access to the EU project."
  record "done" "Zeus plugins of EU mode"
}

# eu_step <function> <name>: runs one EU step in a subshell, so that its failure stops only that step. EU mode is for
# some users only: a failed EU step never stops the Standard setup or the app install. The app reports the missing
# parts when the user switches to EU mode (EUSetup.missing).
eu_step() {
  local summary="$WORK_DIR/eu-step-summary" status line
  : >"$summary"
  set +e
  (
    set -e
    EU_STEP="$2"
    trap 'eu_step_exit $?' EXIT
    SUMMARY=()
    "$1"
    if [ "${#SUMMARY[@]}" -gt 0 ]; then printf '%s\n' "${SUMMARY[@]}" >"$summary"; fi
  )
  status=$?
  set -e
  while IFS= read -r line; do SUMMARY+=("$line"); done <"$summary"
  if [ "$status" -ne 0 ]; then
    SUMMARY+=("$(printf '%-9s %s' "warning" "$2 (not set up; EU mode only)")")
  fi
}

# The EXIT trap of an EU step: a failed command without its own message (no fail) still reports the step as failed.
eu_step_exit() {
  if [ "$1" -ne 0 ] && [ -z "$EU_STEP_REPORTED" ]; then
    fail "$EU_STEP could not be set up (exit code $1)." "See the output above."
  fi
}

install_eu() {
  eu_step install_gcloud "Google Cloud CLI"
  eu_step clone_eu_workspace "EU workspace"
  eu_step install_eu_plugins "Zeus plugins of EU mode"
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

# Prints why the macOS keychain cannot store the Claude login: "none" (no default keychain), "missing" (the default
# keychain file does not exist), or "locked" (it cannot be read). Prints nothing when it is usable. Only reads;
# it never changes a keychain. Without the security command (not macOS) it prints nothing.
keychain_problem() {
  local default_keychain
  command -v security >/dev/null 2>&1 || return 0
  default_keychain="$(security default-keychain -d user 2>/dev/null </dev/null)" || { echo none; return 0; }
  default_keychain="$(printf '%s' "$default_keychain" | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')"
  [ -n "$default_keychain" ] || { echo none; return 0; }
  [ -e "$default_keychain" ] || { echo missing; return 0; }
  security show-keychain-info "$default_keychain" </dev/null >/dev/null 2>&1 || echo locked
}

# Stops with one plain message and the exact fix for the keychain problem. The installer never runs sudo and never
# creates, deletes, or resets a keychain.
# Argument: the problem from keychain_problem.
fail_keychain() {
  local login_keychain='~/Library/Keychains/login.keychain-db' reason
  case "$1" in
    locked) reason="The login keychain of this Mac is locked, so Claude cannot save your login." ;;
    *) reason="This Mac has no usable default keychain, so Claude cannot save your login." ;;
  esac
  fail "$reason" \
    "Do one of these, then go on:" \
    "- Open the Keychain Access app, right-click \"login\", and choose Unlock Keychain." \
    "- Or run: security unlock-keychain $login_keychain" \
    "- If the Mac has no default keychain, run: security default-keychain -s $login_keychain" \
    "If a macOS window says \"Keychain Not Found\", click Cancel. Never click \"Reset To Defaults\": it replaces your login keychain."
}

login_claude() {
  step 13 "Claude login"
  if claude_logged_in; then
    info "Already logged in."
    record "skipped" "Claude login"
    return
  fi
  # Without a keyboard (the app's Try again, or a pipe with no terminal) the login cannot run here.
  if ! { exec 3</dev/tty; } 2>/dev/null; then
    fail "The Claude login needs the Terminal app, and no terminal is connected." \
      "1. Open the Terminal app and run: claude" \
      "2. Log in to Claude there, then type /exit" \
      "Then the setup finds the login and goes on."
  fi
  exec 3<&-
  # The browser login can succeed and then fail when the keychain cannot store it: check before the browser opens.
  local problem login_output status
  problem="$(keychain_problem)"
  if [ -n "$problem" ]; then fail_keychain "$problem"; fi
  info "Your browser opens. Log in to Claude there."
  login_output="$(mktemp "${TMPDIR:-/tmp}/zeus-claude-login.XXXXXX")"
  # The output goes to the screen and to a file. A failed login must not stop the script here (set -e, pipefail).
  set +e
  with_tty claude auth login 2>&1 | tee "$login_output"
  status="${PIPESTATUS[0]}"
  set -e
  if [ "$status" -ne 0 ] || ! claude_logged_in; then
    if grep -q "Couldn't save your login" "$login_output" 2>/dev/null; then
      problem="$(keychain_problem)"
      rm -f "$login_output"
      fail_keychain "${problem:-locked}"
    fi
    rm -f "$login_output"
    fail "The Claude login did not complete."
  fi
  rm -f "$login_output"
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
  if find_gcloud >/dev/null; then state 14 ok; else state 14 todo; fi
  if [ -d "$EU_WORKSPACE/.git" ]; then state 15 ok; else state 15 todo; fi
  if command -v claude >/dev/null 2>&1 && eu_plugins_installed && eu_first_start_done; then state 16 ok; else state 16 todo; fi
  emit "checked"
}

# Prints the tag of the newest Zeus app release ("app-v<version>") in $ZEUS_APP_REPO.
# Drafts, pre-releases, and releases with other tags are not used. Fails without access or without a release.
latest_app_tag() {
  local tags
  tags="$(gh api "repos/$ZEUS_APP_REPO/releases?per_page=100" \
    --jq '.[] | select((.draft or .prerelease) | not) | .tag_name' 2>/dev/null)" || return 1
  printf '%s\n' "$tags" | grep -E '^app-v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1 | grep .
}

# plist_value <app bundle> <key>: prints a value of the Info.plist of the app, or nothing.
plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || true
}

# Downloads the Zeus app release with tag $2 with gh into $1/unpacked/Zeus.app and checks it: the checksum,
# the zip, the bundle identifier, the version, and the signature. On failure, sets APP_ERROR and returns 1.
APP_ERROR=""
download_zeus_app() {
  local dir="$1" tag="$2" version expected actual app
  version="${tag#app-v}"
  info "Downloading the Zeus app $version"
  mkdir -p "$dir"
  if ! gh release download "$tag" -R "$ZEUS_APP_REPO" -p Zeus.zip -p Zeus.zip.sha256 -D "$dir" --clobber \
    </dev/null >"$LOG_DIR/zeus-app.log" 2>&1; then
    APP_ERROR="The download of the Zeus app failed. See the log: $LOG_DIR/zeus-app.log"
    return 1
  fi
  expected="$(awk '{print $1; exit}' "$dir/Zeus.zip.sha256" 2>/dev/null || true)"
  actual="$(shasum -a 256 "$dir/Zeus.zip" | awk '{print $1}')"
  if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
    APP_ERROR="The Zeus app download is damaged or changed (checksum mismatch)."
    return 1
  fi
  app="$dir/unpacked/Zeus.app"
  if ! ditto -x -k "$dir/Zeus.zip" "$dir/unpacked" 2>/dev/null || [ ! -f "$app/Contents/Info.plist" ]; then
    APP_ERROR="The Zeus app download is damaged (no Zeus.app in Zeus.zip)."
    return 1
  fi
  if [ "$(plist_value "$app" CFBundleIdentifier)" != "$APP_BUNDLE_ID" ] ||
    [ "$(plist_value "$app" CFBundleShortVersionString)" != "$version" ]; then
    APP_ERROR="The Zeus app in the download is not Zeus $version."
    return 1
  fi
  if ! codesign --verify --strict "$app" 2>/dev/null; then
    APP_ERROR="The Zeus app in the download is damaged or changed (signature check failed)."
    return 1
  fi
}

# Prints the folder of the Zeus app, as a real path (without symbolic links), because the app compares its own
# path with the path in update.json. The folder is ZEUS_APP_DIR (tests), else the folder of the installed app
# (/Applications, or ~/Applications when it was installed without administrator rights), else /Applications.
# Without write access to the folder, it is ~/Applications.
zeus_app_folder() {
  local folder="${ZEUS_APP_DIR:-}" dir
  if [ -z "$folder" ]; then
    folder=/Applications
    for dir in /Applications "$HOME/Applications"; do
      if [ -d "$dir/Zeus.app" ] && [ -w "$dir" ]; then
        folder="$dir"
        break
      fi
    done
  fi
  if [ ! -w "$folder" ]; then
    folder="$HOME/Applications"
    mkdir -p "$folder"
  fi
  (cd "$folder" && pwd -P)
}

# Prints the process IDs of the running copies of the Zeus app in folder $1. A copy in another folder is not one.
zeus_app_pids() {
  local pattern
  pattern="$(printf '%s' "$1/Zeus.app/Contents/MacOS/Zeus" | sed 's/[][\\.*^$+?(){}|]/\\&/g')"
  pgrep -f "^$pattern" 2>/dev/null || true
}

# Sends the quit Apple event (aevt/quit, without a reply) to the app with process ID $1, as Zeus > Quit Zeus does.
# It goes to the process ID, so a copy of Zeus in another folder does not get it.
send_quit_event() {
  osascript -l JavaScript -e "ObjC.import('Foundation');
    var target = \$.NSAppleEventDescriptor.descriptorWithProcessIdentifier($1);
    var quit = \$.NSAppleEventDescriptor.appleEventWithEventClassEventIDTargetDescriptorReturnIDTransactionID(
      0x61657674, 0x71756974, target, -1, 0);
    quit.sendEventWithOptionsTimeoutError(1, 10, null);" >/dev/null 2>&1
}

# Asks each running copy of the Zeus app in folder $1 to quit, as Zeus > Quit Zeus does: when a tab has unsent
# text, attachments, or work in progress, the app asks first (Quit Anyway or Cancel), and the chats stay in the
# history. Returns 1 when the app is still open after 2 minutes (for example, the user clicked Cancel).
quit_zeus_app() {
  local folder="$1" pid waited=0
  [ -n "$(zeus_app_pids "$folder")" ] || return 0
  info "The Zeus app is open. It now closes as when you quit it."
  info "If a tab has unsent text or Zeus is working, the app asks you first. Your chats stay in the history."
  for pid in $(zeus_app_pids "$folder"); do send_quit_event "$pid" || true; done
  while [ -n "$(zeus_app_pids "$folder")" ] && [ "$waited" -lt 120 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  [ -z "$(zeus_app_pids "$folder")" ]
}

# An update of an installed app keeps the old app until the new app has started, as the app's own update does.
# The file is the one of the app's update (Updater.Pending in app/Sources/Zeus/Updater.swift): the new app
# confirms its start in it when the waiting process (this installer) still runs. When this installer stopped
# before the confirmation, the next start of the new app removes the old copy and the file.
APP_PENDING="$HOME/Library/Application Support/Zeus/update.json"
APP_FOLDER=""
APP_INSTALLED=""
APP_RESULT=""
APP_OLD_VERSION=""
APP_NEW_VERSION=""
APP_BACKUP=""

json_string() {
  local text="${1//\\/\\\\}"
  printf '"%s"' "${text//\"/\\\"}"
}

# The app compares the path in update.json with its own standardized path (Foundation), which has no first
# "/private" when the path without it is the same folder (/private/var is /var). Applications folders do not
# start with /private; the test folders do.
app_standardized_path() {
  local folder="$APP_FOLDER"
  case "$folder" in
    /private/*) if [ "$(cd "${folder#/private}" 2>/dev/null && pwd -P)" = "$folder" ]; then folder="${folder#/private}"; fi ;;
  esac
  printf '%s/Zeus.app' "$folder"
}

write_app_pending() {
  mkdir -p "$(dirname "$APP_PENDING")" &&
    printf '{"from":%s,"to":%s,"appPath":%s,"backupPath":%s,"workPath":%s,"waitingPID":%s,"confirmed":false}\n' \
      "$(json_string "$APP_OLD_VERSION")" "$(json_string "$APP_NEW_VERSION")" "$(json_string "$(app_standardized_path)")" \
      "$(json_string "$APP_BACKUP/Zeus.app")" "$(json_string "$APP_BACKUP")" "$$" >"$APP_PENDING.tmp" &&
    mv -f "$APP_PENDING.tmp" "$APP_PENDING"
}

# Puts the downloaded app ($1) in the place of the app in $APP_FOLDER. An installed app moves to a backup
# folder (APP_BACKUP), outside the work folder, so that it stays when this installer stops. On the same volume,
# both moves are renames. On failure, the installed app stays, APP_ERROR is set, and it returns 1.
replace_zeus_app() {
  local new="$1"
  if [ ! -e "$APP_INSTALLED" ]; then
    mv "$new" "$APP_INSTALLED" && return 0
    APP_ERROR="The Zeus app could not be put in $APP_FOLDER."
    return 1
  fi
  APP_BACKUP="$(mktemp -d "${TMPDIR:-/tmp}/zeus-app-previous.XXXXXX")"
  if ! write_app_pending; then
    rm -rf "$APP_BACKUP" "$APP_PENDING.tmp"
    APP_BACKUP=""
    APP_ERROR="The Zeus app could not prepare the update in $(dirname "$APP_PENDING")."
    return 1
  fi
  if ! mv "$APP_INSTALLED" "$APP_BACKUP/Zeus.app"; then
    rm -rf "$APP_BACKUP"
    rm -f "$APP_PENDING"
    APP_BACKUP=""
    APP_ERROR="The installed Zeus app could not be moved. It is not changed."
    return 1
  fi
  if ! mv "$new" "$APP_INSTALLED"; then
    mv "$APP_BACKUP/Zeus.app" "$APP_INSTALLED"
    rm -rf "$APP_BACKUP"
    rm -f "$APP_PENDING"
    APP_BACKUP=""
    APP_ERROR="The new Zeus app could not be put in $APP_FOLDER. The installed app is not changed."
    return 1
  fi
}

# The new app has started (or is not opened, ZEUS_APP_NO_OPEN): the old copy and update.json are removed.
finish_zeus_app_update() {
  [ -n "$APP_BACKUP" ] || return 0
  rm -rf "$APP_BACKUP"
  rm -f "$APP_PENDING"
  APP_BACKUP=""
}

# Waits up to 60 s for the new app to confirm its start in update.json. Returns 1 when the new app stopped,
# or when no copy of it runs 10 s after the open.
wait_for_zeus_app_start() {
  local waited=0 new_pid
  while [ "$waited" -lt 120 ]; do
    if grep -q '"confirmed" *: *true' "$APP_PENDING" 2>/dev/null; then return 0; fi
    new_pid="$(sed -n 's/.*"newPID" *: *\([0-9][0-9]*\).*/\1/p' "$APP_PENDING" 2>/dev/null || true)"
    if [ -n "$new_pid" ]; then
      kill -0 "$new_pid" 2>/dev/null || return 1
    elif [ "$waited" -ge 20 ] && [ -z "$(zeus_app_pids "$APP_FOLDER")" ]; then
      return 1
    fi
    sleep 0.5
    waited=$((waited + 1))
  done
  return 1
}

# The new app did not start: stops it and puts the old app back. Returns 1 when the old app could not be put back.
# A new copy that wrote its process ID in update.json is at its first launch step, before any Zeus session or
# chat, so it is stopped at once, as the app's own update does. Another copy can have chats, so it gets the
# quit of quit_zeus_app; when it stays open (the user clicked Cancel), the new app stays.
roll_back_zeus_app() {
  local new_pid waited=0
  new_pid="$(sed -n 's/.*"newPID" *: *\([0-9][0-9]*\).*/\1/p' "$APP_PENDING" 2>/dev/null || true)"
  if [ -n "$new_pid" ]; then kill -KILL "$new_pid" 2>/dev/null || true; fi
  while [ -n "$new_pid" ] && kill -0 "$new_pid" 2>/dev/null && [ "$waited" -lt 20 ]; do
    sleep 0.5
    waited=$((waited + 1))
  done
  # Without update.json, a later start of the new app does not remove the old app in APP_BACKUP.
  if ! quit_zeus_app "$APP_FOLDER"; then
    rm -f "$APP_PENDING"
    return 1
  fi
  mkdir -p "$WORK_DIR/zeus-app/not-started"
  if ! mv "$APP_INSTALLED" "$WORK_DIR/zeus-app/not-started/Zeus.app" ||
    ! mv "$APP_BACKUP/Zeus.app" "$APP_INSTALLED"; then
    rm -f "$APP_PENDING"
    return 1
  fi
  rm -rf "$APP_BACKUP"
  rm -f "$APP_PENDING"
  APP_BACKUP=""
}

# open_app [-n]: opens $APP_INSTALLED. -n opens a new copy, also when Zeus runs from another folder.
# ZEUS_APP_TEST_BACKGROUND=1 opens it behind the other apps, and ZEUS_APP_OPEN_ENV (names of environment
# variables, such as HOME) gives these variables to the app (tests).
open_app() {
  local args=("$@") name
  if [ "${ZEUS_APP_TEST_BACKGROUND:-}" = "1" ]; then args+=(-g); fi
  for name in ${ZEUS_APP_OPEN_ENV:-}; do
    if [ -n "${!name+set}" ]; then args+=(--env "$name=${!name}"); fi
  done
  open ${args[@]+"${args[@]}"} "$APP_INSTALLED" >/dev/null 2>&1
}

# Opens the Zeus app. After an update, it waits until the new app has started, as after the app's own update,
# and then removes the old app. When the new app does not start, it puts the old app back and opens it.
# Returns 1 after such a roll back. ZEUS_APP_NO_OPEN=1 (tests) opens nothing and removes the old app.
start_zeus_app() {
  [ -n "$APP_INSTALLED" ] || return 0
  if [ "${ZEUS_APP_NO_OPEN:-}" = "1" ]; then
    finish_zeus_app_update
    return 0
  fi
  if [ "$APP_RESULT" = "current" ]; then
    open_app || true
    return 0
  fi
  if [ -z "$APP_BACKUP" ]; then
    open_app -n || true
    return 0
  fi
  info "Starting the Zeus app $APP_NEW_VERSION"
  if open_app -n && wait_for_zeus_app_start; then
    finish_zeus_app_update
    return 0
  fi
  if roll_back_zeus_app; then
    APP_ERROR="The Zeus app $APP_NEW_VERSION did not start, so your Zeus app $APP_OLD_VERSION is back."
    open_app -n || true
  else
    APP_ERROR="The Zeus app $APP_NEW_VERSION did not start. Your old Zeus app $APP_OLD_VERSION is in $APP_BACKUP/Zeus.app."
  fi
  return 1
}

# A failed app step: with --app-only, the app is what the user asked for, so it stops the installer.
# In Terminal use, it does not stop the installer: Zeus works without the app.
zeus_app_failed() {
  if [ -n "$APP_ONLY" ]; then fail "$APP_ERROR" "$@"; fi
  info "$APP_ERROR"
  info "Zeus works without the app; use the steps below."
  record "failed" "Zeus app"
}

# Step 12 (Terminal use) or step 6 (--app-only) - The Zeus app. It opens Zeus without Terminal and finishes
# the setup in its own window. Step 5 already checked access to the private repo with the app releases.
# An installed app is updated to the newest release. The update changes only the app: the Zeus folder and its
# projects, the Zeus settings, the Claude chats, the plugins, and the app state stay as they are.
install_zeus_app() {
  step "$TOTAL_STEPS" "Zeus app"
  local tag
  APP_FOLDER="$(zeus_app_folder)"
  APP_INSTALLED="$APP_FOLDER/Zeus.app"
  if [ -f "$APP_INSTALLED/Contents/Info.plist" ] &&
    [ "$(plist_value "$APP_INSTALLED" CFBundleIdentifier)" != "$APP_BUNDLE_ID" ]; then
    APP_ERROR="$APP_INSTALLED is another app, not the Zeus app."
    APP_INSTALLED=""
    zeus_app_failed "Rename it or move it to another folder, then run the same line again."
    return
  fi
  if [ -e "$APP_INSTALLED" ]; then APP_OLD_VERSION="$(plist_value "$APP_INSTALLED" CFBundleShortVersionString)"; fi
  if ! tag="$(latest_app_tag)"; then
    APP_ERROR="No Zeus app release was found in $ZEUS_APP_REPO."
    APP_INSTALLED=""
    zeus_app_failed "Check your internet connection, then run the same line again."
    return
  fi
  APP_NEW_VERSION="${tag#app-v}"
  if printf '%s\n' "$APP_OLD_VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' &&
    [ "$(printf '%s\n%s\n' "$APP_OLD_VERSION" "$APP_NEW_VERSION" | sort -V | tail -1)" = "$APP_OLD_VERSION" ]; then
    APP_RESULT="current"
    info "The Zeus app in $APP_FOLDER is already the newest version ($APP_OLD_VERSION)."
    record "skipped" "Zeus app (already the newest version, $APP_OLD_VERSION)"
    return
  fi
  if [ -e "$APP_INSTALLED" ]; then
    info "The Zeus app in $APP_FOLDER is version ${APP_OLD_VERSION:-unknown}; the newest version is $APP_NEW_VERSION."
    if [ -z "$APP_ONLY" ] && [ -n "$(zeus_app_pids "$APP_FOLDER")" ]; then
      info "Quit the Zeus app, then run the same line again to update it."
      APP_INSTALLED=""
      record "skipped" "Zeus app (open, not updated)"
      return
    fi
  fi
  if ! download_zeus_app "$WORK_DIR/zeus-app" "$tag"; then
    APP_INSTALLED=""
    zeus_app_failed "Check your internet connection, then run the same line again."
    return
  fi
  if [ -n "$APP_ONLY" ] && ! quit_zeus_app "$APP_FOLDER"; then
    fail "The Zeus app is still open." "Quit the Zeus app, then run the same line again."
  fi
  # gh does not mark its downloads as downloaded from the internet; this removes a mark from another tool.
  xattr -dr com.apple.quarantine "$WORK_DIR/zeus-app/unpacked/Zeus.app" 2>/dev/null || true
  if ! replace_zeus_app "$WORK_DIR/zeus-app/unpacked/Zeus.app"; then
    APP_INSTALLED=""
    zeus_app_failed "Your projects, chats, and settings did not change."
    return
  fi
  if [ -n "$APP_BACKUP" ]; then
    APP_RESULT="updated"
    info "Put the Zeus app $APP_NEW_VERSION in $APP_FOLDER. The old app stays until the new app has started."
    record "done" "Zeus app (updated from ${APP_OLD_VERSION:-an unknown version} to $APP_NEW_VERSION)"
  else
    APP_RESULT="installed"
    info "Installed $APP_INSTALLED."
    record "done" "Zeus app"
  fi
}

# Opens the app (start_zeus_app). In Terminal use, an update that does not start does not stop the installer.
open_zeus_app() {
  start_zeus_app && return 0
  if [ -n "$APP_ONLY" ]; then fail "$APP_ERROR" "Your projects, chats, and settings did not change."; fi
  info "$APP_ERROR"
  record "failed" "Zeus app (the update did not start)"
}

print_summary() {
  if [ -n "$APP_MODE" ]; then
    emit "finished"
    printf '\n'
    bold "Zeus install is complete."
    return
  fi
  if [ -n "$APP_ONLY" ]; then
    open_zeus_app
    printf '\n'
    case "$APP_RESULT" in
      current)
        bold "The Zeus app is already the newest version ($APP_NEW_VERSION)."
        info "The Zeus app opens now. Your projects, chats, and settings did not change."
        ;;
      updated)
        bold "The Zeus app is updated from ${APP_OLD_VERSION:-an older version} to $APP_NEW_VERSION."
        info "The Zeus app opens now. Your projects, chats, and settings did not change."
        info "The app updates itself when it starts."
        ;;
      *)
        bold "The Zeus app is installed."
        info "The Zeus app opens now. Follow its setup window: it installs the other tools that Zeus needs,"
        info "logs you in to Claude, and keeps Zeus in the Dock. Then click Start Zeus."
        info "Later, click Zeus in the Dock to start Zeus. You do not need Terminal."
        info "The app updates itself when it starts."
        ;;
    esac
    printf '\n'
    return
  fi
  if [ -n "$APP_INSTALLED" ]; then
    open_zeus_app
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
  info "4. Close Claude (Ctrl + C two times), then type these lines one at a time:"
  # --scope user: a plugin or marketplace added at project scope changes the tracked .claude/settings.json
  # of the Zeus folder, and then git pull --ff-only cannot update Zeus.
  local entry
  for entry in $SKILL_PLUGINS; do
    info "     claude plugin marketplace add ${entry#*:} --scope user"
    info "     claude plugin install ${entry%%:*} --scope user"
  done
  info "5. Open a new Terminal window, then type: zeus"
  printf '\n'
}

main() {
  if [ "$(uname -s)" != "Darwin" ]; then
    fail "This installer works only on macOS."
  fi
  if [ "$(id -u)" -eq 0 ]; then
    fail "Do not run this installer with sudo." "Run the install line without sudo."
  fi
  if [ "${1:-}" = "--eu-status-line" ]; then
    eu_mirror_status_line
    return
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
  if [ -n "$APP_ONLY" ] && [ -n "$APP_MODE" ]; then
    fail "--app-only does not work in app mode (ZEUS_INSTALL_APP=1)."
  fi

  bold "Zeus installer"
  if [ -n "$APP_ONLY" ]; then
    info "This checks your GitHub access to Zeus, then installs the Zeus app. Completed steps are skipped."
  else
    info "This installs the tools for Zeus. Completed steps are skipped."
  fi

  # Tools that an earlier run installed in the home folder.
  use_local_path
  if [ -x "$HOME/anaconda3/bin/conda" ]; then
    PATH="$PATH:$HOME/anaconda3/bin"
    export PATH
  fi

  # Before any step: a folder of the user that root owns stops a step half way (for example "mkdir ~/.config/gh:
  # permission denied" after the browser login). A Mac with its own folders passes without any output.
  if [ -n "$APP_ONLY" ]; then
    require_owned "$HOME/.config" "$HOME/.config/gh" "$HOME/.local" "$LOCAL_BIN"
  else
    require_owned "$HOME/.config" "$HOME/.config/gh" "$HOME/.local" "$LOCAL_BIN" "$HOME/.npm" "$HOME/.claude"
  fi

  install_xcode_tools
  install_anaconda
  install_gh
  login_github
  check_access
  if [ -n "$APP_ONLY" ]; then
    install_zeus_app
    print_summary
    return
  fi
  install_node
  install_claude
  install_content_cli
  clone_zeus
  install_editor_plugin
  install_zeus_command
  if [ -n "$APP_MODE" ]; then
    install_skill_plugins
    login_claude
    install_eu
  else
    install_eu
    install_zeus_app
  fi
  print_summary
}

# main is called on the last line, so bash has read the full script before it runs.
# ZEUS_INSTALL_SOURCED=1 loads the functions only, for the tests (app/test/plugin-scope/run.sh and
# app/test/claude-update/run.sh).
if [ "${ZEUS_INSTALL_SOURCED:-}" != "1" ]; then main "$@"; fi
