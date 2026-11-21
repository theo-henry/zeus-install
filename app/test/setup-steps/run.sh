#!/bin/bash
# Unit test of SetupSteps (app/Sources/Zeus/SetupSteps.swift): the lines of install.sh, each legal transition of the run
# phase and of the step state, the events that each state refuses, and the run result (no step without a result is a
# green tick). It gets the keys of the step table of install.sh in app mode, so that the app has a label for each step.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$TEST_DIR/../.." && pwd)"
REPO_DIR="$(dirname "$APP_DIR")"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/zeus-setup-steps.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
keys="$(ZEUS_INSTALL_APP=1 ZEUS_INSTALL_SOURCED=1 bash -c 'source "$1"; step_rows' _ "$REPO_DIR/install.sh" | awk '{ print $2 }')"
swiftc "$APP_DIR/Sources/Zeus/SetupSteps.swift" "$TEST_DIR/main.swift" -o "$WORK/test-setup-steps"
# shellcheck disable=SC2086 # One argument for each key.
"$WORK/test-setup-steps" $keys
