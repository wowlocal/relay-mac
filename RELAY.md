# Relay for macOS

Relay is a Mattermost client built from Telegram's apps. This repository is Telegram for macOS
(TelegramMessenger/telegram-macos at `d19f811484`) with `submodules/telegram-ios` pointed at Relay
([wowlocal/mattermost-tg-client](https://github.com/wowlocal/mattermost-tg-client)), which brings the Mattermost data
layer (MattermostKit, MattermostSyncCore, MattermostSync and the TelegramCore hooks). The macOS UI is this app's own;
Relay's screens are in `packages/RelayUI`.

Setup, the native library build traps, what the app changes, signing and the debug tools are in
[`submodules/telegram-ios/docs/macos-client.md`](submodules/telegram-ios/docs/macos-client.md).

Quick reference:

- Build: `xcodebuild -workspace Telegram-Mac.xcworkspace -scheme Telegram -configuration Debug -derivedDataPath
  /Volumes/X5/relay-mac-dd -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build`
- Sign (GUI session): `tools/relay-mac-sign.sh [path/to/Relay.app]`
- Debug remote: `xcrun swiftc -O -o /tmp/rmr tools/relay-mac-remote.swift && /tmp/rmr action=state`
- Link a local package to the app: `tools/relay-add-package.py <path> <product>`
- Release (GUI session): `RELAY_VERSION=x.y.z tools/relay-mac-release.sh` builds, notarizes, writes the appcast and
  uploads to `macos-releases/relay/`; `tools/relay-mac-publish.sh` uploads a built release again;
  `tools/relay-mac-bucket-keys.sh [--paste]` puts the bucket keys into `~/.relay-secrets/macos-release.env`

Not Telegram: don't call a build of this Telegram, don't use Telegram's logo, don't use Telegram's API credentials
for anything that talks to Telegram (Relay doesn't: with the Mattermost backend every network request is parked).
