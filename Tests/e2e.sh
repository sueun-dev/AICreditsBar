#!/bin/bash
# End-to-end: run the real binary in a throwaway HOME with an isolated defaults
# suite and no Keychain access, and check what it reports. No network needed.
# Usage: bash Tests/e2e.sh <path-to-aicreditsbar-binary>
set -uo pipefail
BIN="${1:?usage: e2e.sh <binary>}"
FAKE="$(mktemp -d)"; SUITE="aicb-e2e-$$"; fail=0
cleanup() { defaults delete "$SUITE" >/dev/null 2>&1 || true; rm -rf "$FAKE"; }
trap cleanup EXIT
run() { HOME="$FAKE" AICB_DEFAULTS_SUITE="$SUITE" AICB_SKIP_KEYCHAIN=1 "$BIN" "$@" 2>&1; }
check() {   # check <output> <expected substring> <description>
  if printf '%s' "$1" | grep -qF -- "$2"; then echo "  ok: $3"
  else echo "  FAIL: $3"; echo "      want: $2"; echo "      got:  $1"; fail=1; fi
}

echo "1) nothing signed in → says so, no numbers"
out="$(run --once)"
check "$out" "Codex: Not signed in to Codex — Run \`codex login\` in Terminal." "Codex asks for codex login"
check "$out" "Claude: Not signed in to Claude Code — Run \`claude\` in Terminal and sign in." "Claude asks for Claude Code login"
if printf '%s' "$out" | grep -q '% left'; then echo "  FAIL: printed a percentage with no data"; fail=1; else echo "  ok: no invented percentages"; fi

echo "2) expired Claude Code login → no request, clear message"
mkdir -p "$FAKE/.claude"
printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat-test","expiresAt":1000,"subscriptionType":"max","rateLimitTier":"default_claude_max_20x"}}' > "$FAKE/.claude/.credentials.json"
check "$(run --once)" "Claude: Claude Code login expired — Open Claude Code once to renew it." "expired login is reported"

echo "3) Codex signed in with an API key → explains there are no plan limits"
mkdir -p "$FAKE/.codex"
printf '{"auth_mode":"apikey","OPENAI_API_KEY":"sk-test"}' > "$FAKE/.codex/auth.json"
check "$(run --once)" "Codex: Codex is signed in with an API key" "API-key login is reported"

echo "4) defaults"
check "$(run --dump-config)" "display=min refresh=300s warn<30% critical<10%" "default settings"

echo "5) renders the menu and the settings window"
run --render-preview "$FAKE/preview.png" >/dev/null && [ -s "$FAKE/preview.png" ] && echo "  ok: preview PNG" || { echo "  FAIL: preview PNG"; fail=1; }
run --render-settings "$FAKE/settings.png" >/dev/null && [ -s "$FAKE/settings.png" ] && echo "  ok: settings PNG" || { echo "  FAIL: settings PNG"; fail=1; }

[ $fail -eq 0 ] && { echo "✓ e2e: all passed"; exit 0; } || { echo "✗ e2e: failures above"; exit 1; }
