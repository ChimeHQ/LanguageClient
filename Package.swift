// swift-tools-version: 5.9

import PackageDescription

let settings: [SwiftSetting] = [
	.enableExperimentalFeature("StrictConcurrency")
]

let package = Package(
	name: "LanguageClient",
	platforms: [.macOS(.v11), .iOS(.v14), .tvOS(.v14), .watchOS(.v7)],
	products: [
		.library(
			name: "LanguageClient",
			targets: ["LanguageClient"]),
	],
	dependencies: [
		.package(url: "https://github.com/ChimeHQ/LanguageServerProtocol", from: "0.13.0"),
		.package(url: "https://github.com/Frizlab/FSEventsWrapper", from: "2.1.0"),
		.package(url: "https://github.com/ChimeHQ/GlobPattern", from: "0.1.1"),
		.package(url: "https://github.com/ChimeHQ/JSONRPC", from: "0.9.0"),
		.package(url: "https://github.com/ChimeHQ/ProcessEnv", from: "1.0.0"),
		.package(url: "https://github.com/groue/Semaphore", from: "0.0.8"),
		.package(url: "https://github.com/mattmassicotte/Queue", from: "0.1.4"),
	],
	targets: [
		.target(
			name: "LanguageClient",
			dependencies: [
				.product(name: "FSEventsWrapper", package: "FSEventsWrapper", condition: .when(platforms: [.macOS])),
				.product(name: "GlobPattern", package: "GlobPattern", condition: .when(platforms: [.macOS])),
				"JSONRPC",
				"LanguageServerProtocol",
				.product(name: "ProcessEnv", package: "ProcessEnv", condition: .when(platforms: [.macOS])),
				"Queue",
				"Semaphore",
			],
			swiftSettings: settings),
		.testTarget(
			name: "LanguageClientTests",
			dependencies: ["LanguageClient"],
			swiftSettings: settings)
	]
)
