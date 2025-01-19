// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LangTools",
    platforms: [
        .macOS(.v14),
        .iOS(.v16),
        .watchOS(.v8)
    ],
    products: [
        .library(name: "LangTools", targets: ["LangTools"]),
        .library(name: "OpenAI", targets: ["OpenAI"]),
        .library(name: "Anthropic", targets: ["Anthropic"]),
        .library(name: "XAI", targets: ["XAI"]),
        .library(name: "Gemini", targets: ["Gemini"]),
        .library(name: "Ollama", targets: ["Ollama"]),
        .executable(name: "ChatCLI", targets: ["ChatCLI"]),
    ],
    targets: [
        // Targets
        .target(name: "LangTools"),
        .target(name: "OpenAI", dependencies: [.target(name: "LangTools")]),
        .target(name: "Anthropic", dependencies: [.target(name: "LangTools")]),
        .target(name: "XAI", dependencies: [ .target(name: "LangTools"), .target(name: "OpenAI"), ]),
        .target(name: "Gemini", dependencies: [ .target(name: "LangTools"), .target(name: "OpenAI"), ]),
        .target(name: "Ollama", dependencies: [ .target(name: "LangTools"), .target(name: "OpenAI"), ]),
        .target(name: "TestUtils", dependencies: [.target(name: "LangTools")], path: "Tests/TestUtils", resources: [.process("Resources/")]),

        // Test targets
        .testTarget(name: "LangToolsTests", dependencies: ["LangTools", "OpenAI", "TestUtils"]),
        .testTarget(name: "OpenAITests", dependencies: ["OpenAI", "TestUtils"]),
        .testTarget(name: "AnthropicTests", dependencies: ["Anthropic", "TestUtils"]),
        .testTarget(name: "XAITests", dependencies: ["XAI", "OpenAI", "TestUtils"]),
        .testTarget(name: "GeminiTests", dependencies: ["Gemini", "OpenAI", "TestUtils"]),
        .testTarget(name: "OllamaTests", dependencies: ["Ollama", "OpenAI", "TestUtils"]),

        // Executable target
        .executableTarget(name: "ChatCLI", dependencies: ["LangTools", "OpenAI", "Anthropic", "XAI", "Gemini", "Ollama"]),
    ]
)
