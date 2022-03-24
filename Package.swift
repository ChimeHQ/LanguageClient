// swift-tools-version:5.3

import PackageDescription

let package = Package(
    name: "LanguageClient",
    platforms: [.macOS(.v10_13), .iOS(.v10), .tvOS(.v10), .watchOS(.v3)],
    products: [
        .library(
            name: "LanguageClient",
            targets: ["LanguageClient"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ChimeHQ/OperationPlus", from: "1.5.4"),
        .package(url: "https://github.com/ChimeHQ/LanguageServerProtocol",  from: "0.5.1"),
        .package(url: "https://github.com/Frizlab/FSEventsWrapper", from: "1.0.1"),
        .package(url: "https://github.com/Bouke/Glob", from: "1.0.5"),
        .package(url: "https://github.com/ChimeHQ/ProcessEnv", from: "0.3.0"),
    ],
    targets: [
        .target(
            name: "LanguageClient",
            dependencies: [
                .productItem(name: "OperationPlus", package: "OperationPlus", condition: nil),
                .productItem(name: "LanguageServerProtocol", package: "LanguageServerProtocol", condition: nil),
                .productItem(name: "ProcessEnv", package: "ProcessEnv", condition: .when(platforms: [.macOS])),
                .productItem(name: "FSEventsWrapper", package: "FSEventsWrapper", condition: .when(platforms: [.macOS])),
                .productItem(name: "Glob", package: "Glob", condition: .when(platforms: [.macOS])),
            ]),
    ]
)
