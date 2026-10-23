#!/bin/bash
# Optional source argument permits a before/after regression check.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SOURCE="${1:-$HERE/../../Sources/RefreshController.swift}"
TASK_TMP="$(mktemp -d -t aicb-refresh-clock)"
trap 'rm -rf "$TASK_TMP"' EXIT
/usr/bin/swiftc -swift-version 5 -warnings-as-errors -O -target "$(uname -m)-apple-macos11" \
  "$SOURCE" "$HERE/main.swift" -o "$TASK_TMP/refresh-clock"
"$TASK_TMP/refresh-clock"
