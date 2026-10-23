#!/bin/bash

# Arguments: explicit override, then `security find-identity -v -p codesigning`.
# Never guess between accounts/certificates. A caller can explicitly request '-'.
select_signing_identity() {
  if [ -n "${1:-}" ]; then
    printf '%s\n' "$1"
    return
  fi
  local identities count
  identities="$(printf '%s\n' "${2:-}" | awk '/"(Apple Development|Developer ID Application):/ {print $2}')"
  count="$(printf '%s\n' "$identities" | awk 'NF {n++} END {print n+0}')"
  if [ "$count" -eq 1 ]; then
    printf '%s\n' "$identities"
  else
    printf '%s\n' '-'
  fi
}
