// swift-tools-version:5.5

import PackageDescription

let settings: [SwiftSetting] = [
	// .unsafeFlags(["-Xfrontend", "-strict-concurrency=complete"])
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
		.package(url: "https://github.com/ChimeHQ/LanguageServerProtocol", revision: "84f1f70b828a993325f408e8e9da6222713702b0"),
		.package(url: "https://github.com/mattmassicotte/FSEventsWrapper", revision: "fb3c520c936d8d3ed69da08e7f1a67516bbd411a"),
		.package(url: "https://github.com/ChimeHQ/GlobPattern", from: "0.1.1"),
		.package(url: "https://github.com/ChimeHQ/ProcessEnv", from: "0.3.0"),
		.package(url: "https://github.com/groue/Semaphore", from: "0.0.8"),
		.package(url: "https://github.com/mattmassicotte/Queue", from: "0.1.4"),
	],
	targets: [
		.target(
			name: "LanguageClient",
			dependencies: [
				"LanguageServerProtocol",
				.product(name: "ProcessEnv", package: "ProcessEnv", condition: .when(platforms: [.macOS])),
				.product(name: "FSEventsWrapper", package: "FSEventsWrapper", condition: .when(platforms: [.macOS])),
				.product(name: "GlobPattern", package: "GlobPattern", condition: .when(platforms: [.macOS])),
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
