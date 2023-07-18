// swift-tools-version:5.5

import PackageDescription

let settings: [SwiftSetting] = [
//	 .unsafeFlags(["-Xfrontend", "-strict-concurrency=complete"])
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
		.package(url: "https://github.com/ChimeHQ/LanguageServerProtocol", revision: "6f05c1b2cc8b3afad83c7cba310b3338199780af"),
		.package(url: "https://github.com/mattmassicotte/FSEventsWrapper", branch: "feature/asyncstream"),
		.package(url: "https://github.com/ChimeHQ/GlobPattern", from: "0.1.1"),
		.package(url: "https://github.com/ChimeHQ/JSONRPC", revision: "42e5e5dd5aace3885d705f6fad50e60ad4cc3c69"),
		.package(url: "https://github.com/ChimeHQ/ProcessEnv", from: "0.3.0"),
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
