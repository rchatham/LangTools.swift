// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LangTools",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .watchOS(.v8)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "LangTools",
            targets: ["LangTools"]),
        .library(
            name: "OpenAI",
            targets: ["OpenAI"]),
        .library(
            name: "Anthropic",
            targets: ["Anthropic"]),
        .library(
            name: "XAI",
            targets: ["XAI"]),
        .library(
            name: "Gemini",
            targets: ["Gemini"]),
//        .executable(name: "ChatCLI", targets: ["ChatCLI"]), // Executable product
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "LangTools"),
        .target(
            name: "OpenAI",
            dependencies: [.target(name: "LangTools")]),
        .target(
            name: "Anthropic",
            dependencies: [.target(name: "LangTools")]),
        .target(
            name: "XAI",
            dependencies: [
                .target(name: "LangTools"),
                .target(name: "OpenAI"),
            ]),
        .target(
            name: "Gemini",
            dependencies: [
                .target(name: "LangTools"),
                .target(name: "OpenAI"),
            ]),
        .testTarget(
            name: "LangToolsTests",
            dependencies: ["LangTools", "OpenAI"],
            resources: [
                .process("Resources/")
            ]),
        .testTarget(
            name: "OpenAITests",
            dependencies: ["OpenAI"],
            resources: [
                .process("Resources/")
            ]),
        .testTarget(
            name: "AnthropicTests",
            dependencies: ["Anthropic"],
            resources: [
                .process("Resources/")
            ]),
        .testTarget(
            name: "XAITests",
            dependencies: ["XAI", "OpenAI", "LangToolsTests"],
            resources: [
                .process("Resources/")
            ]),
        .testTarget(
            name: "GeminiTests",
            dependencies: ["Gemini", "OpenAI", "LangToolsTests"],
            resources: [
                .process("Resources/")
            ]),
//        .executableTarget(
//            name: "ChatCLI", // Executable target
//            dependencies: ["LangTools"] // Depend on the framework
//        ),
    ]
)
