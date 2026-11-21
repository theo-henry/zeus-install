#!/bin/bash
# Regression test of a gcloud that does not run with the Python of macOS (the test-build diagnosis of 2026-11-20): the
# app started with its fallback PATH, which had only Python 3.9, and gcloud 593 (no Python of its own) stopped with
# "gcloud failed to load ... Python 3.9". The Google sign-in then opened nothing and said "did not complete".
# Here the PATH has only a Python 3.9, and a fake gcloud that, like the real one, refuses a Python before 3.10.
# Installer: the step gcloud checks that gcloud runs and gives it a Python 3.10+ of this Mac (CLOUDSDK_PYTHON); without one it
# stops with the gcloud error and the fix; the sign-in step then says that gcloud does not run and asks nothing.
# App: GcloudPython finds the same Python for CLOUDSDK_PYTHON of the commands that it starts (ShellEnvironment.make).
set -uo pipefail
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$TEST_DIR/../.." && pwd)"
REPO_DIR="$(dirname "$APP_DIR")"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/zeus-gcloud-python.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
FAILURES=0
check() { if eval "$2"; then echo "  PASS $1"; else echo "  FAIL $1"; FAILURES=$((FAILURES + 1)); fi; }

# A real Python 3.10 or later of this Mac, for the "Anaconda" of the test home.
GOOD=""
for candidate in "$HOME/anaconda3/bin/python3" /opt/homebrew/bin/python3 /usr/local/bin/python3 \
  $(command -v python3.14 python3.13 python3.12 python3.11 python3.10 python3 2>/dev/null); do
  if [ -x "$candidate" ] && "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then
    GOOD="$candidate"
    break
  fi
done
[ -n "$GOOD" ] || { echo "  FAIL this test needs a Python 3.10 or later on this Mac"; exit 1; }

HOME_DIR="$WORK/home"
OLD="$WORK/old-python"
mkdir -p "$HOME_DIR/google-cloud-sdk/bin" "$HOME_DIR/Library/Logs/zeus-install" "$OLD"
# The only python3 on the PATH is a Python 3.9: it says so to a version check, and runs other scripts.
cat >"$OLD/python3" <<'SH'
#!/bin/sh
case "$*" in *version_info*) exit 1 ;; esac
exec /usr/bin/python3 "$@"
SH
# Like gcloud 593: CLOUDSDK_PYTHON, else python3 of the PATH; a Python before 3.10 stops it at once.
cat >"$HOME_DIR/google-cloud-sdk/bin/gcloud" <<'SH'
#!/bin/sh
python="${CLOUDSDK_PYTHON:-$(command -v python3)}"
if ! "$python" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then
  echo "ERROR: gcloud failed to load. You are running gcloud with Python 3.9, which is no longer supported by gcloud." >&2
  exit 1
fi
printf '%s python=%s\n' "$*" "$python" >>"$HOME/gcloud-calls.log"
case "$*" in
  --version) echo "Google Cloud SDK 593.0.0" ;;
  "auth application-default print-access-token") exit 1 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$OLD/python3" "$HOME_DIR/google-cloud-sdk/bin/gcloud"
FALLBACK_PATH="$OLD:/usr/bin:/bin:/usr/sbin:/sbin"

# run_step <function>: runs one installer step in the test home with the fallback PATH and no system Python folders.
run_step() {
  env -i HOME="$HOME_DIR" PATH="$FALLBACK_PATH" TMPDIR="$WORK" ZEUS_INSTALL_SYSTEM_PYTHON_DIRS="" ZEUS_INSTALL_APP=1 \
    bash -c 'ZEUS_INSTALL_SOURCED=1 source "$1"; WORK_DIR="$(mktemp -d)"; '"$1" _ "$REPO_DIR/install.sh" </dev/null 2>&1
}
check_state() {
  env -i HOME="$HOME_DIR" PATH="$FALLBACK_PATH" TMPDIR="$WORK" ZEUS_INSTALL_SYSTEM_PYTHON_DIRS="" ZEUS_INSTALL_APP=1 \
    bash -c 'ZEUS_INSTALL_SOURCED=1 source "$1"; WORK_DIR="$(mktemp -d)"; state() { echo "state $1 $2"; }; gcloud=""; if gcloud="$(find_gcloud)" && gcloud_runs "$gcloud"; then state gcloud ok; else state gcloud todo; fi' _ "$REPO_DIR/install.sh" </dev/null 2>&1
}

echo "Installer, a Mac with only Python 3.9"
out="$(run_step install_gcloud)"; status=$?
check "the step gcloud does not take a gcloud that does not run as installed" '[ "$status" -ne 0 ] && ! printf "%s" "$out" | grep -q "Already installed"'
check "it says that gcloud does not run, with the gcloud error and the fix" \
  'printf "%s" "$out" | grep -q "The Google Cloud CLI does not run: ERROR: gcloud failed to load. You are running gcloud with Python 3.9" && printf "%s" "$out" | grep -q "installs Python 3.10 or later"'
check "the setup check finds the step gcloud to do" '[ "$(check_state | grep "^state gcloud")" = "state gcloud todo" ]'
out="$(run_step sign_in_google)"
check "the sign-in step says that gcloud does not run" 'printf "%s" "$out" | grep -q "The Google Cloud CLI does not run: ERROR: gcloud failed to load"'
check "it asks no sign-in question, starts no sign-in, and does not say that the sign-in did not complete" \
  '! printf "%s" "$out" | grep -q "Sign in to Google for EU mode now\|No keyboard\|did not complete" && ! grep -q "login" "$HOME_DIR/gcloud-calls.log" 2>/dev/null'

echo "Installer, a Mac with Anaconda in the home folder (not on the PATH)"
mkdir -p "$HOME_DIR/anaconda3/bin"
ln -s "$GOOD" "$HOME_DIR/anaconda3/bin/python3"
out="$(run_step install_gcloud)"; status=$?
check "the step gcloud gives gcloud the Python of Anaconda and says so" \
  '[ "$status" -eq 0 ] && printf "%s" "$out" | grep -q "Zeus runs it with $HOME_DIR/anaconda3/bin/python3 (CLOUDSDK_PYTHON)" && grep -q "^--version python=$HOME_DIR/anaconda3/bin/python3$" "$HOME_DIR/gcloud-calls.log"'
check "the setup check finds the step gcloud done" '[ "$(check_state | grep "^state gcloud")" = "state gcloud ok" ]'

echo "App, GcloudPython"
swiftc "$APP_DIR/Sources/Zeus/GcloudPython.swift" "$TEST_DIR/main.swift" -o "$WORK/test-gcloud-python" 2>&1 | grep -v "warning" || true
mkdir -p "$WORK/newer"
ln -s "$GOOD" "$WORK/newer/python3.12"
"$WORK/test-gcloud-python" "$HOME_DIR" "$OLD" "$WORK/newer" || FAILURES=$((FAILURES + 1))

if [ "$FAILURES" -eq 0 ]; then echo "All checks passed."; exit 0; fi
echo "$FAILURES checks failed."
exit 1
