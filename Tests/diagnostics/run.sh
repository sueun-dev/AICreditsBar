#!/bin/bash
# Build an independent AppKit-only diagnostic. No app settings or usage APIs.
# Usage: bash Tests/diagnostics/run.sh [window|status]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
case "${1:-window}" in
  window) SOURCE="$HERE/main.swift"; SECONDS_TO_EXIT=180 ;;
  status) SOURCE="$HERE/status.swift"; SECONDS_TO_EXIT=8 ;;
  *) echo "Usage: $0 [window|status]" >&2; exit 2 ;;
esac
TASK_TMP="$(mktemp -d -t aicb-capture-diagnostic)"
APP="$TASK_TMP/AICBCaptureDiagnostic.app"
PROBE_PID=""
cleanup() {
  if [ -n "$PROBE_PID" ]; then kill "$PROBE_PID" 2>/dev/null || true; fi
  rm -rf "$TASK_TMP"
}
trap cleanup EXIT
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.sueun.aicreditsbar.capture-diagnostic</string>
<key>CFBundleName</key><string>AICBCaptureDiagnostic</string>
<key>CFBundleExecutable</key><string>capture-diagnostic</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/bin/swiftc -swift-version 5 -warnings-as-errors -target "$(uname -m)-apple-macos11" \
  -framework AppKit "$SOURCE" -o "$APP/Contents/MacOS/capture-diagnostic"
codesign --force --sign - "$APP"
"$APP/Contents/MacOS/capture-diagnostic" &
PROBE_PID=$!
echo "Inspect unified logs for PID $PROBE_PID (capture the window for sharing-indicator faults)."
echo "Temporary app: $APP (exits after $SECONDS_TO_EXIT seconds)."
wait "$PROBE_PID"
PROBE_PID=""
