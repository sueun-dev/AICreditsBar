#!/bin/bash
# Build, then run unit + end-to-end tests. Usage: bash Tests/run.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

echo "── build ──"
bash build.sh >/dev/null && echo "built ✓"

echo "── unit ──"
# Compile the Sources modules (minus the app entry point) together with the unit
# tests, whose top-level code becomes the test binary's main.
SRC=$(ls Sources/*.swift | grep -v 'Sources/main.swift$')
ARCH="$(uname -m)"
/usr/bin/swiftc -swift-version 5 -target "${ARCH}-apple-macos11" -framework AppKit -framework WebKit \
  $SRC Tests/main.swift -o /tmp/aicb-unittests
USUITE="aicb-unit-$$"   # isolated defaults so Cfg-touching tests don't read/clobber real settings
AICB_DEFAULTS_SUITE="$USUITE" /tmp/aicb-unittests; rc=$?
defaults delete "$USUITE" >/dev/null 2>&1 || true
[ $rc -eq 0 ] || exit $rc

echo "── e2e ──"
bash Tests/e2e.sh

echo "── ✓ all tests passed ──"
