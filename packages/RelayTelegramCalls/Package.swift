// swift-tools-version:5.9

import PackageDescription

let deps: [(String, String)] = [
    ("TGUIKit", "../TGUIKit"),
    ("TelegramContext", "../TelegramContext"),
    ("TelegramCallsCore", "../TelegramCallsCore"),
    ("CallVideoLayer", "../CallVideoLayer"),
    ("TelegramMediaUtils", "../TelegramMediaUtils"),
    ("SystemPermissions", "../SystemPermissions"),
    ("Localization", "../Localization"),
]

let package = Package(
    name: "RelayTelegramCalls",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "RelayTelegramCalls", targets: ["RelayTelegramCalls"]),
    ],
    dependencies: [
        .package(name: "SSignalKit", path: "../../submodules/telegram-ios/submodules/SSignalKit"),
        .package(name: "TelegramCore", path: "../../submodules/telegram-ios/submodules/TelegramCore"),
        .package(name: "Postbox", path: "../../submodules/telegram-ios/submodules/Postbox"),
        .package(name: "MetalEngine", path: "../../submodules/telegram-ios/submodules/MetalEngine"),
        .package(name: "TelegramVoip", path: "../../submodules/telegram-ios/submodules/TelegramVoip"),
        .package(name: "TgVoipWebrtc", path: "../../submodules/tgcalls"),
        .package(name: "MattermostSync", path: "../../submodules/telegram-ios/submodules/MattermostSync"),
        .package(name: "RelayCalls", path: "../../submodules/telegram-ios/submodules/RelayCalls"),
        .package(name: "LiveKit", path: "../../submodules/telegram-ios/third-party/livekit-sdk"),
    ] + deps.map { .package(name: $0.0, path: $0.1) },
    targets: [
        .target(
            name: "RelayTelegramCalls",
            dependencies: [
                .product(name: "SwiftSignalKit", package: "SSignalKit", condition: nil),
                .product(name: "TelegramCore", package: "TelegramCore", condition: nil),
                .product(name: "Postbox", package: "Postbox", condition: nil),
                .product(name: "MetalEngine", package: "MetalEngine", condition: nil),
                .product(name: "TelegramVoip", package: "TelegramVoip", condition: nil),
                .product(name: "TgVoipWebrtc", package: "TgVoipWebrtc", condition: nil),
                .product(name: "MattermostSync", package: "MattermostSync", condition: nil),
                .product(name: "RelayCalls", package: "RelayCalls", condition: nil),
                .product(name: "RelayCallsCore", package: "RelayCalls", condition: nil),
                .product(name: "LiveKit", package: "LiveKit", condition: nil),
            ] + deps.map { .product(name: $0.0, package: $0.0, condition: nil) },
            path: "Sources/RelayTelegramCalls",
            swiftSettings: [.unsafeFlags(["-Xcc", "-DWEBRTC_MAC=1"])]),
    ]
)
