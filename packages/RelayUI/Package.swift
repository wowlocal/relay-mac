// swift-tools-version:5.9

import PackageDescription

let deps: [(String, String)] = [
    ("TGUIKit", "../TGUIKit"),
    ("GeneralRows", "../GeneralRows"),
    ("TelegramTheme", "../TelegramTheme"),
    ("InputDataUI", "../InputDataUI"),
]

let package = Package(
    name: "RelayUI",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "RelayUI", targets: ["RelayUI"]),
    ],
    dependencies: [
        .package(name: "SSignalKit", path: "../../submodules/telegram-ios/submodules/SSignalKit"),
        .package(name: "TelegramCore", path: "../../submodules/telegram-ios/submodules/TelegramCore"),
        .package(name: "Postbox", path: "../../submodules/telegram-ios/submodules/Postbox"),
        .package(name: "MattermostKit", path: "../../submodules/telegram-ios/submodules/MattermostKit"),
        .package(name: "MattermostSync", path: "../../submodules/telegram-ios/submodules/MattermostSync"),
    ] + deps.map { .package(name: $0.0, path: $0.1) },
    targets: [
        .target(
            name: "RelayUI",
            dependencies: [
                .product(name: "SwiftSignalKit", package: "SSignalKit", condition: nil),
                .product(name: "TelegramCore", package: "TelegramCore", condition: nil),
                .product(name: "Postbox", package: "Postbox", condition: nil),
                .product(name: "MattermostKit", package: "MattermostKit", condition: nil),
                .product(name: "MattermostSync", package: "MattermostSync", condition: nil),
            ] + deps.map { .product(name: $0.0, package: $0.0, condition: nil) },
            path: "Sources/RelayUI"),
    ]
)
