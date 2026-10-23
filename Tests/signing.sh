#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/../scripts/signing-identity.sh"
DEV='  1) 1111111111111111111111111111111111111111 "Apple Development: Fixture (EXAMPLE)"'
DIST='  2) 2222222222222222222222222222222222222222 "Developer ID Application: Fixture (EXAMPLE)"'
LOCAL='  3) 3333333333333333333333333333333333333333 "Local Fixture"'
test "$(select_signing_identity '' '0 valid identities found')" = '-'
test "$(select_signing_identity '' "$DEV")" = '1111111111111111111111111111111111111111'
test "$(select_signing_identity '' "$DIST")" = '2222222222222222222222222222222222222222'
test "$(select_signing_identity '' "$LOCAL")" = '-'
test "$(select_signing_identity '' "$DEV
$DIST")" = '-'
test "$(select_signing_identity '' "$DEV
$LOCAL")" = '1111111111111111111111111111111111111111'
test "$(select_signing_identity '-' "$DEV")" = '-'
test "$(select_signing_identity 'Explicit Identity' "$DEV
$DIST")" = 'Explicit Identity'
echo '✓ signing: available identity, no certificate, ambiguous accounts and explicit overrides'
