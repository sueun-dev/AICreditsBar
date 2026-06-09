#!/bin/bash
# End-to-end tests: run the built binary against synthetic ~/.codex and ~/.claude
# fixtures in a throwaway HOME with an isolated UserDefaults suite (never touches
# your real settings/tokens), and assert the computed output.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$HERE/AICreditsBar.app/Contents/MacOS/aicreditsbar"
[ -x "$BIN" ] || { echo "build first: bash build.sh" >&2; exit 1; }

FAKE="$(mktemp -d)"; SUITE="aicb-e2e-$$"; fail=0
cleanup() { defaults delete "$SUITE" >/dev/null 2>&1 || true; rm -rf "$FAKE"; }
trap cleanup EXIT
assert() { if printf '%s' "$1" | grep -qF "$2"; then echo "  ok: $3"; else echo "  FAIL: $3"; echo "      want substring: $2"; echo "      in output:      $1"; fail=1; fi }
run() { HOME="$FAKE" AICB_DEFAULTS_SUITE="$SUITE" "$BIN" "$@"; }

python3 - "$FAKE" <<'PY'
import os, sys, json, time
fake = sys.argv[1]; now = time.time()
def iso(t): return time.strftime('%Y-%m-%dT%H:%M:%S.000Z', time.gmtime(t))
d = os.path.join(fake, ".codex/sessions/2026/06/09"); os.makedirs(d)
with open(os.path.join(d, "rollout-test.jsonl"), "w") as f:
    f.write(json.dumps({"timestamp": iso(now-7200)}) + "\n")
    f.write(json.dumps({"timestamp": iso(now-30), "payload": {"type": "token_count", "rate_limits": {
        "primary":   {"used_percent": 40.0, "window_minutes": 300,   "resets_at": int(now + 3600)},
        "secondary": {"used_percent": 70.0, "window_minutes": 10080, "resets_at": int(now + 5*86400)},
        "plan_type": "pro"}}}) + "\n")
p = os.path.join(fake, ".claude/projects/proj"); os.makedirs(p)
with open(os.path.join(p, "s.jsonl"), "w") as f:
    f.write(json.dumps({"type": "assistant", "timestamp": iso(now-600), "requestId": "r1",
        "message": {"id": "m1", "usage": {"input_tokens": 1000000, "output_tokens": 500000,
        "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}}}) + "\n")
PY

echo "1) --once: official Codex from disk rate_limits + Claude 5h estimate"
out="$(run --once)"
assert "$out" "Codex: 5h=60%  week=30%  [pro]" "Codex official 60% (5h) / 30% (week)"
assert "$out" "Claude: 5h=99%" "Claude 5h estimate (1.5M / 220M default)"

echo "2) --dump-config: defaults in the isolated suite"
out="$(run --dump-config)"
assert "$out" "displayMode=5h" "default display mode is 5h"
assert "$out" "plan=Max 20x" "default Claude plan"

echo "3) empty HOME degrades gracefully (no crash, marks unavailable)"
EMPTY="$(mktemp -d)"
out="$(HOME="$EMPTY" AICB_DEFAULTS_SUITE="$SUITE" "$BIN" --once)"
assert "$out" "Codex: [unavailable]" "Codex unavailable with no data"
assert "$out" "Claude: [unavailable]" "Claude unavailable with no data"
rm -rf "$EMPTY"

echo "4) --set-week-used calibrates the weekly budget"
out="$(run --set-week-used 50)"; assert "$out" "Claude weekly calibrated" "calibration ran"
out="$(run --once)";             assert "$out" "7d=50%" "weekly reads 50% left after calibrating to 50% used"

[ $fail -eq 0 ] && { echo "✓ e2e: all passed"; exit 0; } || { echo "✗ e2e: failures above"; exit 1; }
