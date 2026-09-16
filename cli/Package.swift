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
        .package(name: "langtools-cli", path: ".."),
        // Vendored copy of rensbreur/SwiftTUI (rev 5371330) with a thread-safety
        // fix: the upstream renderer and control tree are not safe for
        // concurrent access, and `Application.start()` may run on a different
        // thread than SwiftTUI's main-queue sources (see cli/Vendor/SwiftTUI).
        .package(path: "Vendor/SwiftTUI"),
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
            ],
            path: "Sources/LangToolsCLI"
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
