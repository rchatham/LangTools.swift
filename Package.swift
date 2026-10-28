// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

let extendedTestsEnabled = ProcessInfo.processInfo.environment["LANGTOOLS_ENABLE_EXTENDED_TESTS"] == "1"

let package = Package(
    name: "LangTools",
    platforms: [
        .macOS(.v14),
        .iOS(.v16),
        .watchOS(.v8)
    ],
    products: [
        .library(name: "LangTools", targets: ["LangTools"]),
        .library(name: "HelperLink", targets: ["HelperLink"]),
        .library(name: "Agents", targets: ["Agents"]),
        .library(name: "OpenAI", targets: ["OpenAI"]),
        .library(name: "Anthropic", targets: ["Anthropic"]),
        .library(name: "OpenAICompatible", targets: ["OpenAICompatible"]),
        .library(name: "AnthropicCompatible", targets: ["AnthropicCompatible"]),
        .library(name: "XAI", targets: ["XAI"]),
        .library(name: "Gemini", targets: ["Gemini"]),
        .library(name: "Ollama", targets: ["Ollama"]),
        .library(name: "OpenRouter", targets: ["OpenRouter"]),
        .library(name: "VercelAIGateway", targets: ["VercelAIGateway"]),
        .library(name: "Perplexity", targets: ["Perplexity"]),
        .library(name: "Cohere", targets: ["Cohere"]),
        .library(name: "AppleLangTools", targets: ["AppleLangTools"]),
        .library(name: "WhisperKitLangTools", targets: ["WhisperKitLangTools"]),
    ],
    dependencies: [
        .package(name: "JSON.swift", path: "external/JSON.swift"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.18.0"),
        // Benchmark comparison deps — only used by BenchmarkTests, not linked into any library product.
        // To run competitor benchmarks: uncomment these and the BenchmarkTests product deps below.
        // .package(url: "https://github.com/jamesrochabrun/SwiftOpenAI.git", from: "4.4.0"),
        // .package(url: "https://github.com/jamesrochabrun/SwiftAnthropic.git", from: "2.2.0"),
        // .package(url: "https://github.com/MacPaw/OpenAI.git", from: "0.5.1"),
    ],
    targets: [
        .target(name: "HelperLink"),
        .testTarget(name: "HelperLinkTests", dependencies: ["HelperLink"]),
        .target(name: "LangTools", dependencies: [.product(name: "JSON", package: "JSON.swift")], resources: [.process("README.md")]),
        .target(name: "Agents", dependencies: [.target(name: "LangTools")], resources: [.process("README.md")]),
        .target(name: "OpenAI", dependencies: [.target(name: "LangTools")], resources: [.process("README.md")]),
        .target(name: "Anthropic", dependencies: [.target(name: "LangTools")], resources: [.process("README.md")]),
        .target(name: "OpenAICompatible", dependencies: [.target(name: "LangTools"), .target(name: "OpenAI")], resources: [.process("README.md")]),
        .target(name: "AnthropicCompatible", dependencies: [.target(name: "LangTools"), .target(name: "Anthropic")], resources: [.process("README.md")]),
        .target(name: "XAI", dependencies: [.target(name: "LangTools"), .target(name: "OpenAI"), .target(name: "OpenAICompatible")], resources: [.process("README.md")]),
        .target(name: "Gemini", dependencies: [.target(name: "LangTools"), .target(name: "OpenAI"), .target(name: "OpenAICompatible")], resources: [.process("README.md")]),
        .target(name: "Ollama", dependencies: [.target(name: "LangTools"), .target(name: "OpenAI")], resources: [.process("README.md")]),
        .target(name: "OpenRouter", dependencies: [.target(name: "LangTools"), .target(name: "OpenAI"), .target(name: "OpenAICompatible"), .target(name: "Anthropic"), .target(name: "AnthropicCompatible")], resources: [.process("README.md")]),
        .target(name: "VercelAIGateway", dependencies: [.target(name: "LangTools"), .target(name: "OpenAI"), .target(name: "OpenAICompatible"), .target(name: "Anthropic"), .target(name: "AnthropicCompatible")], resources: [.process("README.md")]),
        .target(name: "Perplexity", dependencies: [.target(name: "LangTools"), .target(name: "OpenAI"), .target(name: "OpenAICompatible")], resources: [.process("README.md")]),
        .target(name: "Cohere", dependencies: [.target(name: "LangTools"), .target(name: "OpenAI"), .target(name: "OpenAICompatible")], resources: [.process("README.md")]),
        .target(name: "AppleLangTools", dependencies: [.target(name: "LangTools")], path: "Sources/Apple", resources: [.process("README.md")]),
        .target(name: "WhisperKitLangTools", dependencies: [.target(name: "LangTools"), .product(name: "WhisperKit", package: "WhisperKit", condition: .when(platforms: [.macOS, .iOS]))], path: "Sources/WhisperKit"),
        .target(name: "TestUtils", dependencies: [.target(name: "LangTools")], path: "Tests/TestUtils", resources: [.process("Resources/")]),

        .testTarget(name: "LangToolsTests", dependencies: ["LangTools", "OpenAI", "Anthropic", "TestUtils"]),
        .testTarget(name: "OpenAITests", dependencies: ["OpenAI", "TestUtils"]),
        .testTarget(name: "AnthropicTests", dependencies: ["Anthropic", "TestUtils"]),
        .testTarget(name: "AnthropicCompatibleTests", dependencies: ["AnthropicCompatible", "Anthropic", "TestUtils"]),
        .testTarget(name: "XAITests", dependencies: ["XAI", "OpenAI", "OpenAICompatible", "TestUtils"]),
        .testTarget(name: "GeminiTests", dependencies: ["Gemini", "OpenAI", "OpenAICompatible", "TestUtils"]),
        .testTarget(name: "OllamaTests", dependencies: ["Ollama", "OpenAI", "TestUtils"]),
        .testTarget(name: "OpenRouterTests", dependencies: ["OpenRouter", "OpenAI", "OpenAICompatible", "Anthropic", "AnthropicCompatible", "TestUtils"]),
        .testTarget(name: "OpenAICompatibleProvidersTests", dependencies: ["VercelAIGateway", "Cohere", "Perplexity", "OpenAI", "OpenAICompatible", "Anthropic", "AnthropicCompatible", "TestUtils"]),
        .testTarget(name: "AppleSpeechTests", dependencies: ["AppleLangTools"]),
        .testTarget(name: "WhisperKitLangToolsTests", dependencies: ["WhisperKitLangTools"]),
    ] + (extendedTestsEnabled ? [
        .testTarget(name: "AgentsTests", dependencies: ["Agents", "LangTools", "OpenAI", "TestUtils"]),

        // Performance & integration test targets
        // ratios.json is read/written via a #filePath-relative path from PerformanceTests,
        // not Bundle.module, so it's excluded from the helper target rather than processed as a resource.
        .target(name: "PerformanceTestUtils", dependencies: [.target(name: "LangTools"), .target(name: "OpenAI"), .target(name: "Anthropic")], path: "Tests/PerformanceTestUtils", exclude: ["ratios.json"]),
        .testTarget(name: "PerformanceTests", dependencies: ["LangTools", "OpenAI", "Anthropic", "TestUtils", "PerformanceTestUtils"]),
        .testTarget(name: "IntegrationTests", dependencies: ["LangTools", "OpenAI", "Anthropic", "TestUtils", "PerformanceTestUtils"]),
        .testTarget(name: "BenchmarkTests", dependencies: [
            "LangTools", "OpenAI", "Anthropic",
            // Uncomment when benchmark deps are enabled above:
            // .product(name: "SwiftOpenAI", package: "SwiftOpenAI"),
            // .product(name: "SwiftAnthropic", package: "SwiftAnthropic"),
            // .product(name: "OpenAI", package: "OpenAI", moduleAliases: ["OpenAI": "MacPawOpenAI"]),
        ]),
    ] : [])
)
