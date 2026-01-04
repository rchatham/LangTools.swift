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
            name: "ExampleAgents",
            targets: ["ExampleAgents"]),
    ],
    dependencies: [
        .package(path: "../../"),
        .package(url: "https://github.com/kishikawakatsumi/KeychainAccess.git", from: "4.0.0"),
        .package(url: "https://github.com/malcommac/SwiftLocation.git", from: "6.0.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "Chat",
            dependencies: [
                .product(name: "LangTools", package: "langtools.swift"),
                .product(name: "Agents", package: "langtools.swift"),
                .product(name: "OpenAI", package: "langtools.swift"),
                .product(name: "Anthropic", package: "langtools.swift"),
                .product(name: "XAI", package: "langtools.swift"),
                .product(name: "Gemini", package: "langtools.swift"),
                .product(name: "Ollama", package: "langtools.swift"),
                .product(name: "AppleSpeech", package: "langtools.swift"),
                "KeychainAccess",
            ],
            path: "Modules/Chat"),
        .target(
            name: "ExampleAgents",
            dependencies: [
                .product(name: "Agents", package: "langtools.swift"),
                "KeychainAccess",
                "SwiftSoup",
            ],
            path: "Modules/Agents"),
    ]
)
