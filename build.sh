#!/bin/bash
# Build AICreditsBar.app — a self-contained LSUIElement menu-bar agent.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/AICreditsBar.app"
STAGING="$(mktemp -d "$HERE/.build-XXXXXX")"
STAGED_APP="$STAGING/AICreditsBar.app"
CONTENTS="$STAGED_APP/Contents"
trap 'rm -rf "$STAGING"' EXIT
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/aicb-module-cache}"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "error: 'swiftc' not found — install Xcode Command Line Tools first:" >&2
  echo "       xcode-select --install" >&2
  exit 1
fi

mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

echo "compiling…"
# Build native arch for this machine, but pin a low min-OS floor (macOS 11, 2020)
# so the binary is portable and the compiler flags any too-new API at build time.
ARCH="$(uname -m)"
/usr/bin/swiftc -swift-version 5 -O -target "${ARCH}-apple-macos11" \
  -framework AppKit \
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
    <key>CFBundleVersion</key>            <string>2</string>
    <key>CFBundleShortVersionString</key> <string>2.0</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>LSMinimumSystemVersion</key>     <string>11.0</string>
    <key>LSUIElement</key>                <true/>
    <key>NSHighResolutionCapable</key>    <true/>
</dict>
</plist>
PLIST

# Ad-hoc sign so it launches cleanly. Surface real failures instead of hiding them.
codesign --force --sign - "$STAGED_APP"

# Replace the installed bundle only after compilation and signing succeed.
if [ -e "$APP" ]; then mv "$APP" "$STAGING/previous.app"; fi
if ! mv "$STAGED_APP" "$APP"; then
  if [ -e "$STAGING/previous.app" ]; then mv "$STAGING/previous.app" "$APP"; fi
  exit 1
fi

echo "Built $APP"

# Restart a running copy on the new build. macOS ties a registered login item to
# the exact (ad-hoc signed) binary it was registered with and refuses to launch a
# rebuilt one, so the login item is re-registered rather than just relaunched.
PLIST="$HOME/Library/LaunchAgents/com.sueun.aicreditsbar.plist"
if [ -f "$PLIST" ] && grep -q "$APP/" "$PLIST"; then
  launchctl bootout "gui/$(id -u)/com.sueun.aicreditsbar" 2>/dev/null || true
  pkill -x aicreditsbar 2>/dev/null || true   # a copy started with `open` would keep the new one out
  launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || { sleep 1; launchctl bootstrap "gui/$(id -u)" "$PLIST"; }
  echo "Restarted the login item on the new build"
elif pkill -x aicreditsbar 2>/dev/null; then
  sleep 1
  open "$APP"
  echo "Restarted AICreditsBar on the new build"
fi
