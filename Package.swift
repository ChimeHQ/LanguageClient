// swift-tools-version: 5.9

import PackageDescription

let package = Package(
	name: "LanguageClient",
	platforms: [
		.macOS(.v11),
		.macCatalyst(.v13),
		.iOS(.v14),
		.tvOS(.v14),
		.watchOS(.v7)
	],
	products: [
		.library(
			name: "LanguageClient",
			targets: ["LanguageClient"]),
	],
	dependencies: [
		.package(url: "https://github.com/ChimeHQ/LanguageServerProtocol", from: "0.13.3"),
		.package(url: "https://github.com/Frizlab/FSEventsWrapper", from: "2.1.0"),
		.package(url: "https://github.com/davbeck/swift-glob", from: "0.0.0"),
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
				.product(name: "Glob", package: "swift-glob"),
				"JSONRPC",
				"LanguageServerProtocol",
				.product(name: "ProcessEnv", package: "ProcessEnv", condition: .when(platforms: [.macOS])),
				"Queue",
				"Semaphore",
			]
		),
		.testTarget(
			name: "LanguageClientTests",
			dependencies: ["LanguageClient"]
		)
	]
)

let swiftSettings: [SwiftSetting] = [
	.enableExperimentalFeature("StrictConcurrency")
]

for target in package.targets {
	var settings = target.swiftSettings ?? []
	settings.append(contentsOf: swiftSettings)
	target.swiftSettings = settings
}
