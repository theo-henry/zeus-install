#!/bin/bash
# Unit test of QuotaProjectDenial (app/Sources/Zeus/EUSignInFailure.swift): which terminal output of the EU sign-in is a
# quota project step that gcloud refused for a missing permission. The sim EU scenario (app/test/sim/run.sh --eu) tests
# the words that the tab then shows.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$TEST_DIR/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/zeus-eu-sign-in.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
swiftc "$APP_DIR/Sources/Zeus/EUSignInFailure.swift" "$TEST_DIR/main.swift" -o "$WORK/test-eu-sign-in"
"$WORK/test-eu-sign-in"
