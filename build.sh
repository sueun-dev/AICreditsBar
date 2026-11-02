#!/bin/bash
# Build AICreditsBar.app — a self-contained LSUIElement menu-bar agent.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/AICreditsBar.app"
source "$HERE/scripts/app-process.sh"
source "$HERE/scripts/signing-identity.sh"
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
cp "$HERE/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"

echo "compiling…"
# Build native arch for this machine (AICB_UNIVERSAL=1: arm64 + x86_64, for releases),
# but pin a low min-OS floor (macOS 11, 2020) so the binary is portable and the
# compiler flags any too-new API at build time.
if [ -n "${AICB_UNIVERSAL:-}" ]; then ARCHS="arm64 x86_64"; else ARCHS="$(uname -m)"; fi
BINARIES=()
for ARCH in $ARCHS; do
  /usr/bin/swiftc -swift-version 5 -O -target "${ARCH}-apple-macos11" \
    -framework AppKit -framework UserNotifications \
    -o "$STAGING/aicreditsbar-$ARCH" "$HERE"/Sources/*.swift
  BINARIES+=("$STAGING/aicreditsbar-$ARCH")
done
/usr/bin/lipo -create "${BINARIES[@]}" -output "$CONTENTS/MacOS/aicreditsbar"
rm -f "${BINARIES[@]}"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>               <string>AICreditsBar</string>
    <key>CFBundleDisplayName</key>        <string>AICreditsBar</string>
    <key>CFBundleIdentifier</key>         <string>com.sueun.aicreditsbar</string>
    <key>CFBundleExecutable</key>         <string>aicreditsbar</string>
    <key>CFBundleIconFile</key>           <string>AppIcon</string>
    <key>CFBundleVersion</key>            <string>3</string>
    <key>CFBundleShortVersionString</key> <string>@VERSION@</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>LSMinimumSystemVersion</key>     <string>11.0</string>
    <key>LSUIElement</key>                <true/>
    <key>NSHighResolutionCapable</key>    <true/>
</dict>
</plist>
PLIST
sed -i '' "s/@VERSION@/$(tr -d '[:space:]' < "$HERE/VERSION")/" "$CONTENTS/Info.plist"

# AppKit registers with App Intents even when the app defines no intents. Current
# macOS rejects that connection without a signing Team ID. Use an available Apple
# identity when unambiguous; keep ad-hoc builds available without a developer account.
AVAILABLE_IDENTITIES=""
if [ -z "${AICB_SIGN_IDENTITY:-}" ]; then
  AVAILABLE_IDENTITIES="$(security find-identity -v -p codesigning)"
fi
SIGN_IDENTITY="$(select_signing_identity "${AICB_SIGN_IDENTITY:-}" "$AVAILABLE_IDENTITIES")"
if [ "$SIGN_IDENTITY" = '-' ]; then
  echo "Signing ad hoc (set AICB_SIGN_IDENTITY to use an Apple signing identity)"
else
  echo "Signing with the selected code-signing identity"
fi
codesign --force ${AICB_SIGN_FLAGS:-} --sign "$SIGN_IDENTITY" "$STAGED_APP"
codesign --verify --strict "$STAGED_APP"

# Replace the installed bundle only after compilation and signing succeed.
if [ -e "$APP" ]; then mv "$APP" "$STAGING/previous.app"; fi
if ! mv "$STAGED_APP" "$APP"; then
  if [ -e "$STAGING/previous.app" ]; then mv "$STAGING/previous.app" "$APP"; fi
  exit 1
fi

echo "Built $APP"

# Refresh Launch Services after replacing the bundle: its record can still describe
# the previous ad-hoc signature, causing App Intents to reject the newly signed app.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"

# Restart a running copy on the new build, re-registering the login item so its
# background-task registration follows the replaced binary.
PLIST="$HOME/Library/LaunchAgents/com.sueun.aicreditsbar.plist"
if [ -f "$PLIST" ] && [ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$PLIST" 2>/dev/null)" = "$APP/Contents/MacOS/aicreditsbar" ]; then
  launchctl bootout "gui/$(id -u)/com.sueun.aicreditsbar" 2>/dev/null || true
  stop_app "$APP/Contents/MacOS/aicreditsbar" || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || { sleep 1; launchctl bootstrap "gui/$(id -u)" "$PLIST"; }
  echo "Restarted the login item on the new build"
elif stop_app "$APP/Contents/MacOS/aicreditsbar"; then
  sleep 1
  open "$APP"
  echo "Restarted AICreditsBar on the new build"
fi
