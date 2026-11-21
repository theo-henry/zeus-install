#!/bin/bash
# Unit test of the app update handoff (app/Sources/Zeus/UpdateHandoff.swift), without app copies: the stages, the legal
# transitions, the role of a copy that starts, and the step of the waiting process (main.swift). Then the contract of
# update.json between the app and install.sh: each side reads the stages that the other writes, the older fields stay
# for app versions before the stage, both take the same lock, and the roll back of install.sh never stops a new app
# that confirmed. The update test (app/test/update/run.sh) tests the same handoff with real app copies.

# check runs its test, in single quotes, with eval; ShellCheck does not see the variables in it.
# shellcheck disable=SC2016
set -uo pipefail
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$TEST_DIR/../.." && pwd)"
REPO_DIR="$(dirname "$APP_DIR")"
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/zeus-update-handoff.XXXXXX")" && pwd -P)"
SLEEPER=""
test_cleanup() {
  [ -z "$SLEEPER" ] || kill -KILL "$SLEEPER" 2>/dev/null || true
  rm -rf "$WORK"
}
trap test_cleanup EXIT
FAILURES=0
check() { if eval "$2"; then echo "  PASS $1"; else echo "  FAIL $1"; FAILURES=$((FAILURES + 1)); fi; }

swiftc "$APP_DIR/Sources/Zeus/UpdateHandoff.swift" "$TEST_DIR/main.swift" -o "$WORK/handoff" 2>&1 | grep -v "warning" || true
"$WORK/handoff" || FAILURES=$((FAILURES + 1))

# install.sh with a test home folder, an Applications folder with the new app, and the old app in its backup folder.
export HOME="$WORK/home"
export ZEUS_INSTALL_SOURCED=1
mkdir -p "$HOME"
# shellcheck source=install.sh
source "$REPO_DIR/install.sh"
# install.sh sets -e; the checks here count failures instead.
set +e
APP_FOLDER="$WORK/Applications"
APP_INSTALLED="$APP_FOLDER/Zeus.app"
APP_OLD_VERSION=1.0.0
APP_NEW_VERSION=1.1.0
WORK_DIR="$WORK/install"
new_update() {
  rm -rf "$APP_FOLDER" "$WORK/backup" "$WORK_DIR" "$APP_PENDING"
  mkdir -p "$APP_INSTALLED" "$WORK/backup/Zeus.app" "$WORK_DIR"
  echo new >"$APP_INSTALLED/version"
  echo old >"$WORK/backup/Zeus.app/version"
  APP_BACKUP="$WORK/backup"
}
app() { "$WORK/handoff" "$@" "$APP_PENDING"; }
# The app commands take the file first.
app_do() { local command="$1"; shift; "$WORK/handoff" "$command" "$APP_PENDING" "$@"; }

echo "install.sh writes, the app reads"
new_update
write_app_pending
check "swapped, with the paths and the process ID of the installer" \
  '[ "$(app decode)" = "swapped from=1.0.0 to=1.1.0 appPath=$(app_standardized_path) backupPath=$WORK/backup/Zeus.app workPath=$WORK/backup waitingPID=$$" ]'
check "with the field confirmed of the older app versions" 'grep -q "\"confirmed\":false" "$APP_PENDING"'
write_app_pending rolledBack
until_now=$(($(date +%s) + 120))
check "rolledBack, with its end in 120 s" \
  'until="$(app decode | sed -n "s/^rolledBack \([0-9]*\) .*/\1/p")"; [ -n "$until" ] && [ $((until_now - until)) -ge 0 ] && [ $((until_now - until)) -le 2 ]'
check "with the field rolledBack of the older app versions" 'grep -q "\"rolledBack\":true" "$APP_PENDING"'

echo "The app writes, install.sh reads"
for stage in swapped newCopyStarted confirmed rolledBack; do
  app_do write "$stage" 4242
  check "$stage" '[ "$(app_pending_stage)" = "$stage" ]'
done
app_do write newCopyStarted 4242
check "the process ID of the new copy" '[ "$(app_pending_new_pid)" = 4242 ]'
rm -f "$APP_PENDING"
check "no file: no stage" '[ -z "$(app_pending_stage)" ]'

echo "install.sh reads the file of an app version before the stage"
legacy() { printf '{"from":"1.0.0","to":"1.1.0","appPath":"\\/a\\/Zeus.app","backupPath":"\\/b","workPath":"\\/c","waitingPID":1%s}' "$1" >"$APP_PENDING"; }
legacy ',"confirmed":false'
check "swapped" '[ "$(app_pending_stage)" = swapped ]'
legacy ',"newPID":4242,"confirmed":false'
check "newCopyStarted" '[ "$(app_pending_stage)" = newCopyStarted ] && [ "$(app_pending_new_pid)" = 4242 ]'
legacy ',"newPID":4242,"confirmed":true'
check "confirmed" '[ "$(app_pending_stage)" = confirmed ]'
legacy ',"confirmed":false,"rolledBack":true'
check "rolledBack" '[ "$(app_pending_stage)" = rolledBack ]'

echo "The lock"
"$WORK/handoff" hold-lock "$APP_PENDING" 2 >"$WORK/lock.out" &
holder=$!
waited=0
until grep -q locked "$WORK/lock.out" 2>/dev/null || [ "$waited" -ge 100 ]; do sleep 0.1; waited=$((waited + 1)); done
started=$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000')
lock_app_pending; locked=$?
took=$(($(perl -MTime::HiRes=time -e 'printf "%d", time * 1000') - started))
unlock_app_pending
wait "$holder"
check "install.sh waits for the lock that the app holds, and then takes it (waited ${took} ms)" '[ "$locked" = 0 ] && [ "$took" -ge 1000 ]'

echo "The roll back of install.sh"
sleep 300 &
SLEEPER=$!
new_update
write_app_pending
app_do write newCopyStarted "$SLEEPER"
claim_app_roll_back
check "the claim makes the stage rolledBack" '[ "$(app_pending_stage)" = rolledBack ]'
check "a new copy that confirms after the claim is refused and quits" 'app_do confirm "$SLEEPER" | grep -q "^refused rolledBack "'

new_update
write_app_pending
app_do write newCopyStarted "$SLEEPER"
check "the new copy confirms" '[ "$(app_do confirm "$SLEEPER")" = applied ]'
status=0
roll_back_zeus_app >/dev/null 2>&1 || status=$?
check "the deadline race: a roll back after the confirmation returns 2 (the update is done)" '[ "$status" = 2 ]'
check "it does not stop the new app that confirmed" 'kill -0 "$SLEEPER" 2>/dev/null'
check "the new app stays in Applications, and the file still says confirmed" \
  '[ "$(cat "$APP_INSTALLED/version")" = new ] && [ "$(app_pending_stage)" = confirmed ]'

new_update
write_app_pending
app_do write newCopyStarted "$SLEEPER"
status=0
roll_back_zeus_app >/dev/null 2>&1 || status=$?
check "a roll back before the confirmation returns 0" '[ "$status" = 0 ]'
check "it stops the new app" 'sleep 0.5; ! kill -0 "$SLEEPER" 2>/dev/null'
check "the old app is back, and the file is removed (the installer opens the old app next)" \
  '[ "$(cat "$APP_INSTALLED/version")" = old ] && [ ! -e "$APP_PENDING" ] && [ ! -e "$WORK/backup" ]'
SLEEPER=""

if [ "$FAILURES" -eq 0 ]; then echo "All checks passed."; exit 0; fi
echo "$FAILURES checks failed."
exit 1
