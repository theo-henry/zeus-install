#!/bin/bash
# Unit test of the chat tab lifecycle (app/Sources/Zeus/TabLifecycle.swift), without app copies and without WebKit: the
# phases, the legal transitions, the epoch that stops a callback of an earlier phase or session, the close request,
# Settings…, and the mode switch (main.swift). app/test/sim/run.sh tests the same lifecycle in the real app.
set -uo pipefail
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$TEST_DIR/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/zeus-tab-lifecycle.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

if ! swiftc "$APP_DIR/Sources/Zeus/TabLifecycle.swift" "$TEST_DIR/main.swift" -o "$WORK/lifecycle" 2>"$WORK/build.log"; then
  cat "$WORK/build.log"
  exit 1
fi
"$WORK/lifecycle"
