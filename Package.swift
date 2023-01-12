// swift-tools-version:5.5

import PackageDescription

let package = Package(
    name: "LanguageClient",
    platforms: [.macOS(.v10_15), .iOS(.v13), .tvOS(.v13), .watchOS(.v6)],
    products: [
        .library(
            name: "LanguageClient",
            targets: ["LanguageClient"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ChimeHQ/OperationPlus", from: "1.6.0"),
		.package(url: "https://github.com/ChimeHQ/LanguageServerProtocol", from: "0.9.0"),
        .package(url: "https://github.com/Frizlab/FSEventsWrapper", from: "1.0.1"),
        .package(url: "https://github.com/Bouke/Glob", from: "1.0.5"),
        .package(url: "https://github.com/ChimeHQ/ProcessEnv", from: "0.3.0"),
    ],
    targets: [
        .target(
            name: "LanguageClient",
            dependencies: [
                .product(name: "OperationPlus", package: "OperationPlus", condition: nil),
                .product(name: "LanguageServerProtocol", package: "LanguageServerProtocol", condition: nil),
                .product(name: "ProcessEnv", package: "ProcessEnv", condition: .when(platforms: [.macOS])),
                .product(name: "FSEventsWrapper", package: "FSEventsWrapper", condition: .when(platforms: [.macOS])),
                .product(name: "Glob", package: "Glob", condition: .when(platforms: [.macOS])),
            ]),
    ]
)
