#!/bin/bash
# Register (or remove with -u) a LaunchAgent so AICreditsBar starts at login.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"   # project root (this script lives in scripts/)
LABEL="com.sueun.aicreditsbar"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BIN="$HERE/AICreditsBar.app/Contents/MacOS/aicreditsbar"

if [[ "${1:-}" == "-u" || "${1:-}" == "--uninstall" ]]; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    pkill -x aicreditsbar 2>/dev/null || true
    echo "Removed login item."
    exit 0
fi

if [[ ! -x "$BIN" ]]; then echo "Build first: bash build.sh"; exit 1; fi

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>            <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$BIN</string></array>
    <key>RunAtLoad</key>        <true/>
    <key>KeepAlive</key>        <dict><key>SuccessfulExit</key><false/></dict>
    <key>ProcessType</key>      <string>Interactive</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed login item → $PLIST"
echo "AICreditsBar will now start automatically at login (and is running now)."
