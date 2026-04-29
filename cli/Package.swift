// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "LangToolsCLI",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "langtools", targets: ["CLI"]),
    ],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/rensbreur/SwiftTUI", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "CLI",
            dependencies: [
                .product(name: "LangTools", package: "langtools-cli"),
                .product(name: "OpenAI", package: "langtools-cli"),
                .product(name: "Anthropic", package: "langtools-cli"),
                .product(name: "XAI", package: "langtools-cli"),
                .product(name: "Gemini", package: "langtools-cli"),
                .product(name: "Ollama", package: "langtools-cli"),
                .product(name: "Agents", package: "langtools-cli"),
                .product(name: "SwiftTUI", package: "SwiftTUI"),
            ]
        ),
        .testTarget(
            name: "CLITests",
            dependencies: [
                "CLI",
                .product(name: "LangTools", package: "langtools-cli"),
                .product(name: "OpenAI", package: "langtools-cli"),
                .product(name: "Ollama", package: "langtools-cli"),
            ]
        ),
    ]
)
