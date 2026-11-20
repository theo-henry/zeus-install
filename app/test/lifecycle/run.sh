#!/bin/bash
# Unit test of AppLifecycle (app/Sources/Zeus/AppLifecycle.swift): each legal transition of the app phase and of the quit
# phase, and the events that each phase refuses. The sim quit scenario (app/test/sim/run.sh --quit) tests the quit
# question whose window closes in the real app.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$TEST_DIR/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/zeus-lifecycle.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
swiftc "$APP_DIR/Sources/Zeus/AppLifecycle.swift" "$TEST_DIR/main.swift" -o "$WORK/test-lifecycle"
"$WORK/test-lifecycle"
