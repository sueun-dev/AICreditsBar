#!/bin/bash
# Regenerate the checked-in icon; normal app builds need no artwork tooling.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/aicb-icon.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/aicb-module-cache}"
mkdir -p "$HERE/Resources" "$HERE/docs/images"
/usr/bin/swift "$HERE/scripts/render-app-icon.swift" \
  "$STAGING/AppIcon.iconset" "$STAGING/app-icon.png"
/usr/bin/iconutil --convert icns --output "$STAGING/AppIcon.icns" "$STAGING/AppIcon.iconset"
cp "$STAGING/AppIcon.icns" "$HERE/Resources/AppIcon.icns"
cp "$STAGING/app-icon.png" "$HERE/docs/images/app-icon.png"
echo "Updated Resources/AppIcon.icns and docs/images/app-icon.png"
