#!/bin/bash
# Signs a built Relay.app with a local identity ("Apple Development" by default, RELAY_SIGN_IDENTITY to change it),
# inside out: nested frameworks, dylibs and helper apps, then the app with Telegram-Mac/Relay.entitlements. Needs a
# GUI security session (Rex, Terminal): an agent's background shell gets errSecInternalComponent. A stable signature
# keeps the app's Keychain access across rebuilds. Log: build/relay-mac-sign.log, ending with exit=N.
#   tools/relay-mac-sign.sh [path/to/Relay.app]
set -uo pipefail
cd "$(dirname "$0")/.."
APP="${1:-/Volumes/X5/relay-mac-dd/Build/Products/Debug/Relay.app}"
IDENTITY="${RELAY_SIGN_IDENTITY:-Apple Development}"
mkdir -p build
LOG="build/relay-mac-sign.log"
: > "$LOG"
HASH="$(security find-identity -v -p codesigning | grep "\"$IDENTITY" | head -1 | awk '{print $2}')"
if [ -z "$HASH" ]; then
    echo "no \"$IDENTITY\" identity in the keychain" | tee -a "$LOG"
    echo "exit=1" >> "$LOG"
    exit 1
fi
OPTIONS=(--force --sign "$HASH" --timestamp=none)
if [ "${RELAY_HARDENED:-0}" = "1" ]; then
    OPTIONS=(--force --sign "$HASH" --timestamp --options runtime)
fi
STATUS=0
MAIN="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
while IFS= read -r -d '' item; do
    if [ "$item" != "$MAIN" ] && file -b "$item" | grep -q "Mach-O"; then
        codesign "${OPTIONS[@]}" "$item" >> "$LOG" 2>&1 || STATUS=1
    fi
done < <(find "$APP/Contents" -type f -perm +111 -print0)
while IFS= read -r -d '' item; do
    codesign "${OPTIONS[@]}" "$item" >> "$LOG" 2>&1 || STATUS=1
done < <(find "$APP/Contents" -depth \( -name "*.framework" -o -name "*.dylib" -o -name "*.app" -o -name "*.xpc" -o -name "*.appex" \) -print0)
codesign "${OPTIONS[@]}" --entitlements Telegram-Mac/Relay.entitlements "$APP" >> "$LOG" 2>&1 || STATUS=1
codesign --verify --deep --strict "$APP" >> "$LOG" 2>&1 || STATUS=1
echo "exit=$STATUS" >> "$LOG"
echo "exit=$STATUS"
