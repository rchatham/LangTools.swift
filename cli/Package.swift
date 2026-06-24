// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LangToolsCLI",
    platforms: [
        .macOS(.v14),
        .iOS(.v16),
        .watchOS(.v8)
    ],
    products: [
        .executable(name: "LangToolsCLI", targets: ["LangToolsCLI"]),
    ],
    dependencies: [
        .package(name: "langtools.swift", path: ".."),
    ],
    targets: [
        .executableTarget(
            name: "LangToolsCLI",
            dependencies: [
                .product(name: "LangTools", package: "langtools.swift"),
                .product(name: "OpenAI", package: "langtools.swift"),
                .product(name: "Anthropic", package: "langtools.swift"),
                .product(name: "XAI", package: "langtools.swift"),
                .product(name: "Gemini", package: "langtools.swift"),
                .product(name: "Ollama", package: "langtools.swift"),
            ]
        )
    ]
)
