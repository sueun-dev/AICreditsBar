#!/bin/bash
# The update sections that need the developer's certificate: the signature check on
# real builds, staging signed and tampered downloads, and scripts/release.sh.
# Builds from a copy of this checkout, so the installed app and its login item are
# never touched. Skips on a Mac without a matching Apple Development certificate.
# Usage: bash Tests/updater/run.sh   (two universal builds, a few minutes)
set -euo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
source "$HERE/scripts/signing-identity.sh"
PINNED="$(sed -n 's/.*publisherTeam = "\(.*\)".*/\1/p' "$HERE/Sources/Updater.swift")"
IDENTITY="$(select_signing_identity "${AICB_SIGN_IDENTITY:-}" "$(security find-identity -v -p codesigning)")"
if [ "$IDENTITY" = '-' ]; then echo "skip updater: no Apple Development certificate on this Mac"; exit 0; fi

WORK="$(mktemp -d -t aicb-updater)"
trap 'rm -rf "$WORK"' EXIT
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/aicb-module-cache}"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

echo "── updater: build the checker ──"
SOURCES=()
for file in "$HERE"/Sources/*.swift; do [ "$(basename "$file")" = main.swift ] || SOURCES+=("$file"); done
/usr/bin/swiftc -swift-version 5 -target "$(uname -m)-apple-macos11" -framework AppKit -framework UserNotifications \
  "${SOURCES[@]}" "$HERE/Tests/updater/main.swift" -o "$WORK/updater-check"
CHECK="$WORK/updater-check"

echo "── updater: ⑨ release script ──"
rsync -a --exclude .git --exclude AICreditsBar.app --exclude dist --exclude .codeatlas "$HERE/" "$WORK/repo/"
echo 9.9.9 > "$WORK/repo/VERSION"
ZIP="$WORK/repo/dist/AICreditsBar.zip"
if AICB_SIGN_IDENTITY=- bash "$WORK/repo/scripts/release.sh" >"$WORK/adhoc.log" 2>&1; then fail "an ad-hoc build was released"; fi
grep -q "installed copies only accept '$PINNED'" "$WORK/adhoc.log" || fail "ad-hoc refusal did not name the pinned team"
[ ! -e "$ZIP" ] || fail "a refused build still left a zip"
ok "an ad-hoc build is refused and no zip is made"

AICB_SIGN_IDENTITY="$IDENTITY" bash "$WORK/repo/scripts/release.sh" >"$WORK/release.log" 2>&1 || { cat "$WORK/release.log"; fail "release.sh"; }
[ -z "$(zipinfo -1 "$ZIP" | grep -v '^AICreditsBar.app/')" ] || fail "the zip holds files outside AICreditsBar.app/"
ok "the zip holds only AICreditsBar.app at its root"
mkdir "$WORK/unzipped"
/usr/bin/ditto -x -k "$ZIP" "$WORK/unzipped"
APP="$WORK/unzipped/AICreditsBar.app"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" = 9.9.9 ] || fail "VERSION did not reach Info.plist"
ok "VERSION becomes the app version"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/aicreditsbar")"
[[ " $ARCHS " == *" arm64 "* && " $ARCHS " == *" x86_64 "* ]] || fail "not universal: $ARCHS"
ok "universal binary ($ARCHS)"
codesign --verify --strict --deep "$APP" || fail "the unzipped app's signature is broken"
SIGNATURE="$(codesign -dvv "$APP" 2>&1)"
grep -q "^TeamIdentifier=$PINNED$" <<<"$SIGNATURE" || fail "signed by the wrong team"
grep -q "^Timestamp=" <<<"$SIGNATURE" || fail "no secure timestamp, so the signature would expire with the certificate"
ok "signed by team $PINNED with a secure timestamp, intact after zip and unzip"
INTEL="$(arch -x86_64 "$APP/Contents/MacOS/aicreditsbar" --render-settings "$WORK/intel.png" 2>&1)" || true
if grep -q "Bad CPU type" <<<"$INTEL"; then
  echo "skip: Rosetta is not installed, so the Intel slice was not run"
else
  [ -s "$WORK/intel.png" ] || fail "the Intel slice did not run: $INTEL"
  ok "the Intel slice runs under Rosetta"
fi

echo "── updater: ⑥ signature on real builds ──"
copy() { mkdir -p "$WORK/$1"; cp -R "$APP" "$WORK/$1/AICreditsBar.app"; echo "$WORK/$1/AICreditsBar.app"; }
ADHOC="$(copy adhoc)"; codesign --force --sign - "$ADHOC" 2>/dev/null
TAMPERED="$(copy tampered)"; printf x >> "$TAMPERED/Contents/Resources/AppIcon.icns"
OTHER="$(copy other-id)"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.example.other' "$OTHER/Contents/Info.plist"
codesign --force --sign "$IDENTITY" "$OTHER" 2>/dev/null
"$CHECK" verify "$APP" || fail "the release build was not accepted"
ok "the release build is accepted"
! "$CHECK" verify "$APP" ABCDE12345 || fail "another team was accepted"
ok "the same build is refused for another team"
! "$CHECK" verify "$ADHOC" || fail "an ad-hoc re-sign was accepted"
ok "an ad-hoc re-signed copy is refused"
! "$CHECK" verify "$TAMPERED" || fail "a modified resource was accepted"
ok "a copy with one changed byte is refused"
! "$CHECK" verify "$OTHER" || fail "another bundle identifier was accepted"
ok "another app signed by the same team is refused"

echo "── updater: ⑦ staging downloads ──"
# The app stages in the per-user temp folder (NSTemporaryDirectory ignores TMPDIR).
STAGING_ROOT="$(getconf DARWIN_USER_TEMP_DIR)"
staged() { ls -A "$STAGING_ROOT" | grep '^aicb-update-' || true; }
BEFORE="$(staged)"
zipped() { /usr/bin/ditto -c -k --keepParent "$1" "$WORK/$2.zip"; echo "$WORK/$2.zip"; }
expect() {   # expect <reason> <zip> <version>
  local got; got="$("$CHECK" stage "$2" "$3")" || true
  [ "$got" = "$1" ] || fail "staging $(basename "$2") as $3: got '$got', want '$1'"
}
expect "ok" "$ZIP" 9.9.9
ok "the release zip is staged"
expect "The download is not AICreditsBar 9.9.8" "$ZIP" 9.9.8
ok "a zip whose app is another version is refused"
UNSIGNED="The download is not signed by the developer, so it was not installed"
expect "$UNSIGNED" "$(zipped "$ADHOC" adhoc)" 9.9.9
expect "$UNSIGNED" "$(zipped "$TAMPERED" tampered)" 9.9.9
expect "$UNSIGNED" "$(zipped "$OTHER" other-id)" 9.9.9
ok "ad-hoc, tampered and other-identifier zips are refused"
head -c "$(( $(stat -f %z "$ZIP") / 2 ))" "$ZIP" > "$WORK/truncated.zip"
expect "The download is not AICreditsBar 9.9.9" "$WORK/truncated.zip" 9.9.9
ok "a truncated download is refused"
mkdir "$WORK/renamed"; cp -R "$APP" "$WORK/renamed/Other.app"
expect "The download is not AICreditsBar 9.9.9" "$(zipped "$WORK/renamed/Other.app" renamed)" 9.9.9
ok "a zip without AICreditsBar.app is refused"
[ "$(staged)" = "$BEFORE" ] || fail "staging left folders behind in $STAGING_ROOT"
ok "nothing is left in the temp folder"

echo "── ✓ updater: certificate-dependent sections passed ──"
