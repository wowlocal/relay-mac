#!/bin/bash
# A Relay for macOS release, as Snippets ships (wowlocal/snippets Distribution/Release): notarized app, Sparkle appcast,
# both on the macos-releases bucket (Yandex Object Storage) under relay/, where the app's SUFeedURL points.
#
#   1. Release build (CFBundleVersion = commit count of HEAD, so every release is newer; RELAY_VERSION sets the
#      marketing version), stripped copy, Developer ID signature with the hardened runtime, notarization (App Store
#      Connect API key in ~/.relay-secrets/asc), stapled ticket, zip.
#   2. build/updates/ keeps every released zip and its release notes (Relay-<version>-<build>.html: RELAY_NOTES, or
#      the "Relay for macOS:" commit subjects since the last relay-mac-* tag). Every item needs a description: Relay up
#      to 1.0.1 (22) crashes on an update without one. Sparkle 2's generate_appcast writes appcast.xml from them, signed with
#      Relay's EdDSA key (~/.relay-secrets/sparkle/relay-mac-ed25519.key, its public half is SUPublicEDKey). No deltas:
#      the app's Sparkle is 1.21, which can't apply Sparkle 2's delta format.
#   3. Upload of the zip and appcast.xml with curl's AWS SigV4 (no aws CLI), settings from
#      ~/.relay-secrets/macos-release.env (S3_BUCKET, S3_ENDPOINT, S3_REGION, S3_PREFIX, AWS_ACCESS_KEY_ID,
#      AWS_SECRET_ACCESS_KEY; the same bucket and keys as Snippets' Distribution/.env, prefix relay). Without that file
#      the appcast is made but nothing is uploaded. Then the tag relay-mac-<version>-<build> is pushed and
#      tools/relay-mac-github-release.sh makes the GitHub release with a notarized DMG.
#
# RELAY_PRERELEASE=1 makes a GitHub pre-release only: the zip and notes go to build/prerelease/ (never build/updates/,
# which every appcast is generated from), nothing is uploaded to the bucket, so no installed Relay is offered the
# build, and the tag and GitHub release (marked pre-release, not latest) are made as usual.
#
# Run in a GUI session (codesign). Log: build/relay-mac-release.log, ending with exit=N.
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
LOG="build/relay-mac-release.log"
exec > >(tee "$LOG") 2>&1
fail() { echo "error: $1"; echo "exit=1"; exit 1; }

DERIVED_DATA="${RELAY_DERIVED_DATA:-/Volumes/X5/relay-mac-dd}"
ASC_KEY="${RELAY_ASC_KEY:-$(ls "$HOME"/.relay-secrets/asc/ApiKey_*.p8 2>/dev/null | head -1)}"
ED_KEY="${RELAY_ED_KEY:-$HOME/.relay-secrets/sparkle/relay-mac-ed25519.key}"
ENV_FILE="${RELAY_RELEASE_ENV:-$HOME/.relay-secrets/macos-release.env}"
SPARKLE_VERSION="2.9.5"
SPARKLE_BIN="build/sparkle-$SPARKLE_VERSION/bin"
[ -f "$ASC_KEY" ] || fail "no App Store Connect API key"
[ -f "$ED_KEY" ] || fail "no EdDSA key at $ED_KEY"
ASC_KEY_ID="$(basename "$ASC_KEY" .p8 | sed 's/^ApiKey_//')"
if [ -n "$(git status --porcelain --untracked-files=no -- . ':!submodules/Sparkle' ':!submodules/tg_owt')" ]; then
    fail "uncommitted changes: the build number is the commit count, commit first"
fi
BUILD="$(git rev-list --count HEAD)"
VERSION_ARGS=(CURRENT_PROJECT_VERSION="$BUILD")
if [ -n "${RELAY_VERSION:-}" ]; then
    VERSION_ARGS+=(MARKETING_VERSION="$RELAY_VERSION")
fi

if [ ! -x "$SPARKLE_BIN/generate_appcast" ]; then
    echo "== Sparkle $SPARKLE_VERSION tools"
    mkdir -p "build/sparkle-$SPARKLE_VERSION"
    curl -sSL -o "build/sparkle-$SPARKLE_VERSION/Sparkle.tar.xz" "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
        && tar -xJf "build/sparkle-$SPARKLE_VERSION/Sparkle.tar.xz" -C "build/sparkle-$SPARKLE_VERSION" || fail "Sparkle tools"
fi

echo "== build $BUILD"
xcodebuild -workspace Telegram-Mac.xcworkspace -scheme Telegram -configuration Release -derivedDataPath "$DERIVED_DATA" \
    -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO "${VERSION_ARGS[@]}" build > build/relay-mac-release-xcodebuild.log 2>&1 \
    || fail "xcodebuild (build/relay-mac-release-xcodebuild.log)"
PLIST="$DERIVED_DATA/Build/Products/Release/Relay.app/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")" = "$BUILD" ] || fail "CFBundleVersion is not $BUILD"

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
xcrun notarytool submit build/Relay-notarize.zip --key "$ASC_KEY" --key-id "$ASC_KEY_ID" --wait | tail -3 | tee build/relay-mac-notarize.log
grep -q "status: Accepted" build/relay-mac-notarize.log || fail "notarization"
rm -f build/Relay-notarize.zip
xcrun stapler staple build/Relay.app || fail "staple"
spctl -a -vv build/Relay.app 2>&1 | head -2

echo "== zip"
ZIP_NAME="Relay-$VERSION-$BUILD.zip"
UPDATES_DIR="build/updates"
[ "${RELAY_PRERELEASE:-}" = 1 ] && UPDATES_DIR="build/prerelease"
mkdir -p "$UPDATES_DIR"
rm -f "$UPDATES_DIR/$ZIP_NAME"
ditto -c -k --keepParent build/Relay.app "$UPDATES_DIR/$ZIP_NAME"

echo "== release notes"
NOTES_FILE="$UPDATES_DIR/Relay-$VERSION-$BUILD.html"
PREVIOUS_TAG="$(git describe --tags --abbrev=0 --match 'relay-mac-*' 2>/dev/null || true)"
RELAY_NOTES="${RELAY_NOTES:-}" PREVIOUS_TAG="$PREVIOUS_TAG" python3 -I - "$NOTES_FILE" <<'PY' || fail "release notes"
import html, os, subprocess, sys
notes = os.environ["RELAY_NOTES"].strip()
if notes:
    lines = [line.strip("-• ").strip() for line in notes.splitlines() if line.strip()]
else:
    tag = os.environ["PREVIOUS_TAG"]
    log = subprocess.run(["git", "log", "--format=%s"] + ([f"{tag}..HEAD"] if tag else []), capture_output=True, text=True, check=True).stdout
    prefix = "Relay for macOS: "
    lines = [s[len(prefix):] for s in log.splitlines() if s.startswith(prefix)]
    lines = [s[:1].upper() + s[1:] for s in lines] or ["Fixes and improvements."]
with open(sys.argv[1], "w") as f:
    f.write("<ul>" + "".join(f"<li>{html.escape(line)}</li>" for line in lines) + "</ul>\n")
PY
cat "$NOTES_FILE"

echo "== appcast"
if [ -f "$ENV_FILE" ]; then
    set -a
    . "$ENV_FILE"
    set +a
fi
S3_ENDPOINT="${S3_ENDPOINT:-https://storage.yandexcloud.net}"
S3_BUCKET="${S3_BUCKET:-macos-releases}"
S3_PREFIX="${S3_PREFIX:-relay}"
S3_REGION="${S3_REGION:-ru-central1}"
DOWNLOAD_PREFIX="$S3_ENDPOINT/$S3_BUCKET/$S3_PREFIX/"
"$SPARKLE_BIN/generate_appcast" --ed-key-file "$ED_KEY" --download-url-prefix "$DOWNLOAD_PREFIX" --maximum-deltas 0 build/updates \
    || fail "generate_appcast"
grep -q "<sparkle:version>$BUILD</sparkle:version>" build/updates/appcast.xml || fail "appcast has no item for $BUILD"
[ "$(grep -c '<item>' build/updates/appcast.xml)" = "$(grep -c '<description>' build/updates/appcast.xml)" ] \
    || fail "an appcast item has no description (Relay up to 1.0.1 crashes on it)"

if [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
    echo "no upload keys ($ENV_FILE): build/updates/$ZIP_NAME and build/updates/appcast.xml are ready, nothing uploaded"
    echo "exit=0"
    exit 0
fi

echo "== upload to $DOWNLOAD_PREFIX"
upload() {
    curl --silent --show-error --fail --aws-sigv4 "aws:amz:$S3_REGION:s3" --user "$AWS_ACCESS_KEY_ID:$AWS_SECRET_ACCESS_KEY" \
        --header "Content-Type: $2" --upload-file "$1" "$DOWNLOAD_PREFIX$(basename "$1")" || fail "upload of $(basename "$1")"
}
upload "build/updates/$ZIP_NAME" application/zip
upload build/updates/appcast.xml application/xml
curl -sf "${DOWNLOAD_PREFIX}appcast.xml" | grep -q "<sparkle:version>$BUILD</sparkle:version>" || fail "the published appcast has no item for $BUILD"

TAG="relay-mac-$VERSION-$BUILD"
git tag "$TAG" && git push -q origin "$TAG" || echo "warning: tag $TAG not pushed"
echo "released $VERSION ($BUILD): ${DOWNLOAD_PREFIX}$ZIP_NAME"

echo "== github release"
bash tools/relay-mac-github-release.sh build/Relay.app | tail -1 | grep -q "exit=0" || fail "GitHub release (build/relay-mac-github-release.log)"
grep "^released:" build/relay-mac-github-release.log
echo "exit=0"
