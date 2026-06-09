#!/bin/bash
# Build AICreditsBar.app — a self-contained LSUIElement menu-bar agent.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/AICreditsBar.app"
CONTENTS="$APP/Contents"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "error: 'swiftc' not found — install Xcode Command Line Tools first:" >&2
  echo "       xcode-select --install" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

echo "compiling…"
# Build native arch for this machine, but pin a low min-OS floor (macOS 11, 2020)
# so the binary is portable and the compiler flags any too-new API at build time.
ARCH="$(uname -m)"
/usr/bin/swiftc -swift-version 5 -O -target "${ARCH}-apple-macos11" \
  -framework AppKit -framework WebKit \
  -o "$CONTENTS/MacOS/aicreditsbar" "$HERE"/Sources/*.swift

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>               <string>AICreditsBar</string>
    <key>CFBundleDisplayName</key>        <string>AICreditsBar</string>
    <key>CFBundleIdentifier</key>         <string>com.sueun.aicreditsbar</string>
    <key>CFBundleExecutable</key>         <string>aicreditsbar</string>
    <key>CFBundleVersion</key>            <string>1</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>LSMinimumSystemVersion</key>     <string>11.0</string>
    <key>LSUIElement</key>                <true/>
    <key>NSHighResolutionCapable</key>    <true/>
</dict>
</plist>
PLIST

# Ad-hoc sign so it launches cleanly. Surface real failures instead of hiding them.
codesign --force --sign - "$APP" || echo "warning: ad-hoc codesign failed (app still runs locally)" >&2

echo "Built $APP"
