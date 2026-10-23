#!/bin/bash
# Exercise restart scoping with disposable executables, including a relative
# launch from a path with spaces. Never targets the installed app.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
source "$HERE/scripts/app-process.sh"
TASK_TMP="$(mktemp -d)"
first=""; second=""
cleanup() {
    [ -z "$first" ] || kill "$first" 2>/dev/null || true
    [ -z "$second" ] || kill "$second" 2>/dev/null || true
    rm -rf "$TASK_TMP"
}
trap cleanup EXIT
mkdir "$TASK_TMP/one app" "$TASK_TMP/two app"
printf '#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n' > "$TASK_TMP/sleeper.c"
/usr/bin/clang "$TASK_TMP/sleeper.c" -o "$TASK_TMP/one app/aicreditsbar"
cp "$TASK_TMP/one app/aicreditsbar" "$TASK_TMP/two app/aicreditsbar"
"$TASK_TMP/one app/aicreditsbar" 30 & first=$!
(cd "$TASK_TMP/two app" && exec ./aicreditsbar 30) & second=$!
sleep 0.1
stop_app "$TASK_TMP/one app/aicreditsbar"
wait "$first" 2>/dev/null || true; first=""
kill -0 "$second"   # another checkout with the same executable name survives
stop_app "$TASK_TMP/two app/aicreditsbar"
wait "$second" 2>/dev/null || true; second=""
echo "✓ restart scoping: absolute and relative paths, spaces, other copy preserved"
