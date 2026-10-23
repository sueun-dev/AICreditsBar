#!/bin/bash
# Unit + end-to-end tests. Builds throwaway binaries in a temp dir, so the
# installed AICreditsBar.app and its login item are never touched.
# Usage: bash Tests/run.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/aicb-module-cache}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
SWIFTC=(/usr/bin/swiftc -swift-version 5 -target "$(uname -m)-apple-macos11" -framework AppKit -framework UserNotifications)

echo "── unit ──"
# The Sources (minus the app entry point) plus the tests, whose top-level code is the test main.
SRC=$(ls Sources/*.swift | grep -v 'Sources/main.swift$')
"${SWIFTC[@]}" $SRC Tests/*.swift -o "$OUT/unittests"
SUITE="aicb-unit-$$"   # isolated defaults so tests never read or change the real settings
rc=0; AICB_DEFAULTS_SUITE="$SUITE" AICB_SKIP_KEYCHAIN=1 "$OUT/unittests" || rc=$?
defaults delete "$SUITE" >/dev/null 2>&1 || true
[ $rc -eq 0 ] || exit $rc

echo "── e2e ──"
"${SWIFTC[@]}" -O Sources/*.swift -o "$OUT/aicreditsbar"
bash Tests/e2e.sh "$OUT/aicreditsbar"
bash Tests/processes.sh
bash Tests/signing.sh
bash Tests/refresh-clock/run.sh
python3 Tests/test_resources.py
python3 Tests/test_energy.py

echo "── ✓ all tests passed ──"
