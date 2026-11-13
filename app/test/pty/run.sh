#!/bin/bash
set -euo pipefail
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$TEST_DIR/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/zeus-pty.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
printf 'module CPTY { header "%s/Sources/CPTY/include/cpty.h" export * }\n' "$APP_DIR" > "$WORK/module.modulemap"
clang -I "$APP_DIR/Sources/CPTY/include" -c "$APP_DIR/Sources/CPTY/cpty.c" -o "$WORK/cpty.o"
swiftc -I "$WORK" "$APP_DIR/Sources/Zeus/PTYProcess.swift" "$TEST_DIR/main.swift" "$WORK/cpty.o" -o "$WORK/test-pty"
"$WORK/test-pty"
