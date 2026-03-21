// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LangTools_Example",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .watchOS(.v8),
    ],
    products: [
        .library(
            name: "Chat",
            targets: ["Chat"]),
        .library(
            name: "Audio",
            targets: ["Audio"]),
        .library(
            name: "ExampleAgents",
            targets: ["ExampleAgents"]),
    ],
    dependencies: [
        .package(path: "../../"),
        .package(path: "../../../ChatUI/"),
        .package(url: "https://github.com/kishikawakatsumi/KeychainAccess.git", from: "4.0.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.6.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
    ],
    targets: [
        .target(
            name: "Chat",
            dependencies: [
                .product(name: "LangTools", package: "langtools-ai-tool-configuration"),
                .product(name: "Agents", package: "langtools-ai-tool-configuration"),
                .product(name: "OpenAI", package: "langtools-ai-tool-configuration"),
                .product(name: "Anthropic", package: "langtools-ai-tool-configuration"),
                .product(name: "XAI", package: "langtools-ai-tool-configuration"),
                .product(name: "Gemini", package: "langtools-ai-tool-configuration"),
                .product(name: "Ollama", package: "langtools-ai-tool-configuration"),
                .product(name: "AppleSpeech", package: "langtools-ai-tool-configuration"),
                .product(name: "ToolKit", package: "langtools-ai-tool-configuration"),
                "KeychainAccess",
            ],
            path: "Modules/Chat"),
        .target(
            name: "Audio",
            dependencies: [
                .product(name: "ChatUI", package: "ChatUI"),
                .product(name: "OpenAI", package: "langtools-ai-tool-configuration"),
                .product(name: "LangTools", package: "langtools-ai-tool-configuration"),
                .product(name: "WhisperKit", package: "WhisperKit", condition: .when(platforms: [.macOS, .iOS])),
                "Chat",
            ],
            path: "Modules/Audio"),
        .target(
            name: "ExampleAgents",
            dependencies: [
                .product(name: "Agents", package: "langtools-ai-tool-configuration"),
                .product(name: "ToolKit", package: "langtools-ai-tool-configuration"),
                "Chat",
                "KeychainAccess",
                "SwiftSoup",
            ],
            path: "Modules/ExampleAgents"),
    ]
)
