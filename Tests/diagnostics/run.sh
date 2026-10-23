#!/bin/bash
# Build an independent AppKit-only capture diagnostic. No app settings or APIs.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
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
  -framework AppKit "$HERE/main.swift" -o "$APP/Contents/MacOS/capture-diagnostic"
codesign --force --sign - "$APP"
"$APP/Contents/MacOS/capture-diagnostic" &
PROBE_PID=$!
echo "Capture this window, then inspect unified logs for PID $PROBE_PID."
echo "Temporary app: $APP (exits after 180 seconds)."
wait "$PROBE_PID"
PROBE_PID=""
