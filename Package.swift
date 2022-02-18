// swift-tools-version:5.5
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LanguageClient",
    platforms: [.macOS(.v10_12), .iOS(.v10), .tvOS(.v10), .watchOS(.v3)],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "LanguageClient",
            targets: ["LanguageClient"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ChimeHQ/OperationPlus", from: "1.5.4"),
        .package(url: "https://github.com/ChimeHQ/LanguageServerProtocol", .branch("main")),
        .package(url: "https://github.com/Frizlab/FSEventsWrapper", from: "1.0.1"),
        .package(url: "https://github.com/Bouke/Glob", from: "1.0.5"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "LanguageClient",
            dependencies: ["OperationPlus", "LanguageServerProtocol", "FSEventsWrapper", "Glob"]),
        .testTarget(
            name: "LanguageClientTests",
            dependencies: ["LanguageClient"]),
    ]
)
