#!/bin/bash
# Runs every test of the repo, one after the other, with a hard time bound on each test.
# .github/workflows/ci.yml and commands.test in .no-mistakes.yaml both run this script.
#
# Each test starts in its own process group. It gets one start line and one end line with its duration.
# When a test runs longer than its bound, the group gets TERM (the test cleans up and stops its Zeus copies),
# and 10 s later KILL. The script then fails with the name of the test, and no later test runs.
# macOS has no GNU timeout, so a bash watchdog does this.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"

# run_test <name> <limit in seconds> <command> [argument...]
run_test() {
  local name="$1" limit="$2" start=$SECONDS pid watchdog status
  shift 2
  echo "=== START $name (limit ${limit}s)"
  # With job control, the background job is the leader of a new process group.
  set -m
  "$@" &
  pid=$!
  set +m
  (
    sleep "$limit"
    echo "=== TIMEOUT $name after ${limit}s: stopping it" >&2
    kill -TERM -- "-$pid" 2>/dev/null
    sleep 10
    kill -KILL -- "-$pid" 2>/dev/null
  ) &
  watchdog=$!
  wait "$pid"
  status=$?
  # Stop the watchdog first, then its sleep (a child of the watchdog), so that it does not report a timeout.
  kill "$watchdog" 2>/dev/null || true
  pkill -P "$watchdog" 2>/dev/null || true
  { wait "$watchdog"; } 2>/dev/null || true
  # Stop what the test left in its group.
  kill -KILL -- "-$pid" 2>/dev/null || true
  local took=$((SECONDS - start))
  if [ "$status" -ne 0 ]; then
    echo "=== FAIL $name after ${took}s (exit $status)"
    exit 1
  fi
  echo "=== END $name after ${took}s"
}

# A release build must ignore the test settings: the app reads ZEUS_APP_* and ZEUS_EDITOR_STATE_DIR only through
# DebugEnvironment.value (app/Sources/Zeus/Environment.swift), which is empty outside debug builds.
direct_reads="$(grep -rnE 'environment\[\"ZEUS_|env\[\"ZEUS_(APP_|EDITOR_STATE_DIR)' "$TEST_DIR/../Sources" || true)"
if [ -n "$direct_reads" ]; then
  echo "=== FAIL debug settings: read ZEUS_APP_* and ZEUS_EDITOR_STATE_DIR only through DebugEnvironment.value:"
  echo "$direct_reads"
  exit 1
fi
echo "=== END debug settings check"

run_test "pty" 300 "$TEST_DIR/pty/run.sh"
run_test "plugin-scope" 300 "$TEST_DIR/plugin-scope/run.sh"
# Each update part builds the development app first (swift build): on a busy Mac that alone can take minutes.
run_test "update install" 600 "$TEST_DIR/update/run.sh" install
run_test "update app" 600 "$TEST_DIR/update/run.sh" app
run_test "update upgrade" 600 "$TEST_DIR/update/run.sh" upgrade
run_test "sim" 600 "$TEST_DIR/sim/run.sh"
run_test "sim eu" 600 "$TEST_DIR/sim/run.sh" --eu
