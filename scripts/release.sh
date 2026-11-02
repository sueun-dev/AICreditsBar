#!/bin/bash
# Build the release zip that installed copies download when you choose "Update".
# Usage: bash scripts/release.sh   → dist/AICreditsBar.zip (publish it with the printed gh command)
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$HERE/VERSION")"

# Universal binary, signed with a trusted timestamp so the signature outlives the certificate.
AICB_UNIVERSAL=1 AICB_SIGN_FLAGS="--timestamp" bash "$HERE/build.sh"

APP="$HERE/AICreditsBar.app"
TEAM="$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
PINNED="$(sed -n 's/.*publisherTeam = "\(.*\)".*/\1/p' "$HERE/Sources/Updater.swift")"
if [ "$TEAM" != "$PINNED" ]; then
  echo "error: the app is signed by team '${TEAM:-none}' but installed copies only accept '$PINNED'." >&2
  echo "       Build with the Apple Development certificate: AICB_SIGN_IDENTITY=<its name or hash> bash scripts/release.sh" >&2
  exit 1
fi

mkdir -p "$HERE/dist"
rm -f "$HERE/dist/AICreditsBar.zip"
/usr/bin/ditto -c -k --keepParent "$APP" "$HERE/dist/AICreditsBar.zip"
echo
echo "Built dist/AICreditsBar.zip for v$VERSION. Publish it with:"
echo "  gh release create v$VERSION dist/AICreditsBar.zip --title \"AICreditsBar $VERSION\" --notes \"…\""
