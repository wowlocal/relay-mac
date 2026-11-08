#!/bin/bash
# Publishes a built, notarized Relay.app as a GitHub release of wowlocal/relay-mac (tag relay-mac-<version>-<build>),
# with a DMG to download: the app beside an Applications link, signed with the app's Developer ID identity, notarized
# and stapled. The notes are the release's (build/updates/Relay-<version>-<build>.html). tools/relay-mac-release.sh
# runs it after the appcast upload; on its own it takes the app (default build/Relay.app).
#
# RELAY_PRERELEASE=1 marks the release as a pre-release (not latest); RELAY_UPDATES_DIR is where the notes are.
#
# Run in a GUI session (codesign). Log: build/relay-mac-github-release.log, ending with exit=N.
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
exec > >(tee build/relay-mac-github-release.log) 2>&1
fail() { echo "error: $1"; echo "exit=1"; exit 1; }

APP="${1:-build/Relay.app}"
REPO="${RELAY_GITHUB_REPO:-wowlocal/relay-mac}"
ASC_KEY="${RELAY_ASC_KEY:-$(ls "$HOME"/.relay-secrets/asc/ApiKey_*.p8 2>/dev/null | head -1)}"
[ -f "$ASC_KEY" ] || fail "no App Store Connect API key"
ASC_KEY_ID="$(basename "$ASC_KEY" .p8 | sed 's/^ApiKey_//')"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" || fail "no app at $APP"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
TAG="relay-mac-$VERSION-$BUILD"
NOTES_HTML="${RELAY_UPDATES_DIR:-build/updates}/Relay-$VERSION-$BUILD.html"
[ -f "$NOTES_HTML" ] || fail "no release notes at $NOTES_HTML"
xcrun stapler validate -q "$APP" || fail "$APP is not notarized and stapled (tools/relay-mac-release.sh makes it)"

echo "== dmg"
DMG="build/dmg/Relay-$VERSION.dmg"
STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/Relay.app" && ln -s /Applications "$STAGE/Applications" || fail "staging"
mkdir -p build/dmg
rm -f "$DMG"
hdiutil create -quiet -volname "Relay $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG" || fail "hdiutil"
rm -rf "$STAGE"

echo "== sign"
IDENTITY="${RELAY_SIGN_IDENTITY:-Developer ID Application}"
HASH="$(security find-identity -v -p codesigning | grep "\"$IDENTITY" | head -1 | awk '{print $2}')"
[ -n "$HASH" ] || fail "no \"$IDENTITY\" identity in the keychain"
codesign --force --sign "$HASH" --timestamp "$DMG" || fail "codesign"

echo "== notarize"
xcrun notarytool submit "$DMG" --key "$ASC_KEY" --key-id "$ASC_KEY_ID" --wait | tail -3 | tee build/relay-mac-dmg-notarize.log
grep -q "status: Accepted" build/relay-mac-dmg-notarize.log || fail "notarization"
xcrun stapler staple "$DMG" || fail "staple"
spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 | head -2

echo "== github release $TAG"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || fail "no tag $TAG"
git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null || git push -q origin "$TAG" || fail "pushing $TAG"
NOTES_MD="build/dmg/Relay-$VERSION-$BUILD.md"
python3 -I - "$NOTES_HTML" "$NOTES_MD" "$(basename "$DMG")" <<'PY' || fail "notes"
import html, re, sys
items = [html.unescape(re.sub(r"<[^>]+>", "", i)).strip() for i in re.findall(r"<li>(.*?)</li>", open(sys.argv[1]).read(), re.S)]
with open(sys.argv[2], "w") as f:
    f.write("".join(f"- {i}\n" for i in items))
    f.write(f"\nDownload **{sys.argv[3]}**, open it and drag Relay into Applications (macOS 13 or later, Apple silicon "
            "and Intel). An installed Relay updates itself.\n")
PY
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
    gh release upload "$TAG" "$DMG" --clobber -R "$REPO" || fail "uploading the DMG"
else
    if [ "${RELAY_PRERELEASE:-}" = 1 ]; then RELEASE_KIND=(--prerelease --latest=false); else RELEASE_KIND=(--latest); fi
    gh release create "$TAG" "$DMG" -R "$REPO" --title "Relay $VERSION ($BUILD)" --notes-file "$NOTES_MD" "${RELEASE_KIND[@]}" \
        || fail "creating the release"
fi
echo "released: https://github.com/$REPO/releases/tag/$TAG"
echo "exit=0"
