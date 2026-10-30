#!/bin/bash
# A distributable Relay for macOS: Release build, stripped copy, Developer ID signature with the hardened runtime,
# notarization (App Store Connect API key, RELAY_ASC_KEY=path/to/ApiKey_<id>.p8, default the one in
# ~/.relay-secrets/asc), stapled ticket, zip. Run in a GUI session (codesign); the log is build/relay-mac-release.log,
# ending with exit=N. Output: build/Relay-<version>-macos-arm64.zip.
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
LOG="build/relay-mac-release.log"
exec > >(tee "$LOG") 2>&1
fail() { echo "error: $1"; echo "exit=1"; exit 1; }
DERIVED_DATA="${RELAY_DERIVED_DATA:-/Volumes/X5/relay-mac-dd}"
KEY="${RELAY_ASC_KEY:-$(ls "$HOME"/.relay-secrets/asc/ApiKey_*.p8 2>/dev/null | head -1)}"
[ -f "$KEY" ] || fail "no App Store Connect API key"
KEY_ID="$(basename "$KEY" .p8 | sed 's/^ApiKey_//')"

echo "== build"
xcodebuild -workspace Telegram-Mac.xcworkspace -scheme Telegram -configuration Release -derivedDataPath "$DERIVED_DATA" \
    -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build > build/relay-mac-release-xcodebuild.log 2>&1 \
    || fail "xcodebuild (build/relay-mac-release-xcodebuild.log)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DERIVED_DATA/Build/Products/Release/Relay.app/Contents/Info.plist")"

echo "== strip"
rm -rf build/Relay.app
ditto "$DERIVED_DATA/Build/Products/Release/Relay.app" build/Relay.app
xcrun strip -S -x build/Relay.app/Contents/MacOS/Relay || fail "strip"

echo "== sign"
RELAY_SIGN_IDENTITY="Developer ID Application" RELAY_HARDENED=1 bash tools/relay-mac-sign.sh build/Relay.app | tail -1 | grep -q "exit=0" \
    || fail "signing (build/relay-mac-sign.log)"

echo "== notarize"
rm -f build/Relay-notarize.zip
ditto -c -k --keepParent build/Relay.app build/Relay-notarize.zip
xcrun notarytool submit build/Relay-notarize.zip --key "$KEY" --key-id "$KEY_ID" --wait | tail -3 | tee build/relay-mac-notarize.log
grep -q "status: Accepted" build/relay-mac-notarize.log || fail "notarization"
rm -f build/Relay-notarize.zip
xcrun stapler staple build/Relay.app || fail "staple"
spctl -a -vv build/Relay.app 2>&1 | head -2

echo "== zip"
ZIP="build/Relay-$VERSION-macos-arm64.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/Relay.app "$ZIP"
echo "$ZIP"
echo "exit=0"
