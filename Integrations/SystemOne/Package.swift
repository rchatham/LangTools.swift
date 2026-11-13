// swift-tools-version: 6.0

import PackageDescription

// A separate package so that System One's MLX stack and exact dependency pins
// reach only the apps that opt in, not every consumer of LangTools.
let package = Package(
    name: "SystemOneLangTools",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "SystemOneLangTools", targets: ["SystemOneLangTools"]),
    ],
    dependencies: [
        .package(name: "langtools.swift", path: "../../"),
        // 0.x minor releases may break the API, so stay within 0.2.
        .package(url: "https://github.com/rchatham/SystemOne.swift.git", .upToNextMinor(from: "0.2.0")),
    ],
    targets: [
        .target(
            name: "SystemOneLangTools",
            dependencies: [
                .product(name: "LangTools", package: "langtools.swift"),
                .product(name: "SystemOne", package: "SystemOne.swift"),
                .product(name: "SystemOneChat", package: "SystemOne.swift"),
                .product(name: "SystemOneD1", package: "SystemOne.swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SystemOneLangToolsTests",
            dependencies: ["SystemOneLangTools"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
