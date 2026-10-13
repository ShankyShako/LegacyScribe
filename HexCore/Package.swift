// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HexCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HexCore", targets: ["HexCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Clipy/Sauce", branch: "master"),
        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.11.0"),
        .package(url: "https://github.com/apple/swift-log", from: "1.9.1"),
        .package(url: "https://github.com/pointfreeco/xctest-dynamic-overlay", from: "1.8.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
    ],
    targets: [
	    .target(
	        name: "HexCore",
	        dependencies: [
	            "Sauce",
	            .product(name: "Dependencies", package: "swift-dependencies"),
	            .product(name: "DependenciesMacros", package: "swift-dependencies"),
	            .product(name: "Logging", package: "swift-log"),
	            // @DependencyClient expands to IssueReporting calls; without this the dynamic
	            // HexCore framework Xcode builds for the test host fails to link.
	            .product(name: "IssueReporting", package: "xctest-dynamic-overlay"),
	            .product(name: "GRDB", package: "GRDB.swift"),
	        ],
	        path: "Sources/HexCore",
	        linkerSettings: [
	            .linkedFramework("IOKit")
	        ]
	    ),
        .testTarget(
            name: "HexCoreTests",
            dependencies: ["HexCore"],
            path: "Tests/HexCoreTests",
            resources: [
                .copy("Fixtures")
            ]
        ),
    ]
)
