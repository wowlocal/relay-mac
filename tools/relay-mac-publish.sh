#!/bin/bash
# Uploads what tools/relay-mac-release.sh built: build/updates/appcast.xml and every zip it references, to the bucket in
# ~/.relay-secrets/macos-release.env (curl AWS SigV4), then checks the published appcast. For a release whose upload
# was skipped (no keys yet) or failed. Log: build/relay-mac-publish.log, ending with exit=N.
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
exec > >(tee build/relay-mac-publish.log) 2>&1
fail() { echo "error: $1"; echo "exit=1"; exit 1; }
ENV_FILE="${RELAY_RELEASE_ENV:-$HOME/.relay-secrets/macos-release.env}"
[ -f "$ENV_FILE" ] || fail "no $ENV_FILE"
set -a
. "$ENV_FILE"
set +a
[ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ] || fail "no upload keys in $ENV_FILE"
PREFIX="${S3_ENDPOINT:-https://storage.yandexcloud.net}/${S3_BUCKET:-macos-releases}/${S3_PREFIX:-relay}/"
APPCAST=build/updates/appcast.xml
[ -f "$APPCAST" ] || fail "no $APPCAST (run tools/relay-mac-release.sh)"
upload() {
    curl --silent --show-error --fail --aws-sigv4 "aws:amz:${S3_REGION:-ru-central1}:s3" --user "$AWS_ACCESS_KEY_ID:$AWS_SECRET_ACCESS_KEY" \
        --header "Content-Type: $2" --upload-file "$1" "$PREFIX$(basename "$1")" || fail "upload of $(basename "$1")"
    echo "uploaded $(basename "$1")"
}
for url in $(grep -oE 'url="[^"]+"' "$APPCAST" | sed -E 's/^url="([^"]+)"/\1/'); do
    name="$(basename "$url")"
    [ "$url" = "$PREFIX$name" ] || fail "$name is not under $PREFIX"
    if curl -sfI "$url" >/dev/null; then
        echo "already published: $name"
    else
        [ -f "build/updates/$name" ] || fail "missing build/updates/$name"
        upload "build/updates/$name" application/zip
    fi
done
upload "$APPCAST" application/xml
LATEST="$(grep -oE '<sparkle:version>[0-9]+' "$APPCAST" | sed 's/.*>//' | sort -n | tail -1)"
curl -sf "${PREFIX}appcast.xml" | grep -q "<sparkle:version>$LATEST</sparkle:version>" || fail "the published appcast has no item for $LATEST"
echo "published: ${PREFIX}appcast.xml (latest $LATEST)"
echo "exit=0"
