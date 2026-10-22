// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PublicHelperAPISmoke",
    platforms: [.macOS(.v14)],
    products: [.library(name: "PublicHelperAPISmoke", targets: ["PublicHelperAPISmoke"])],
    dependencies: [
        .package(name: "ProviderStack", path: "../.."),
        .package(name: "HelperPackage", path: "../../cli"),
        .package(name: "ChatPackage", path: "../../Apps/LangTools"),
    ],
    targets: [
        .target(name: "PublicHelperAPISmoke", dependencies: [
            .product(name: "HelperLink", package: "ProviderStack"),
            .product(name: "Ollama", package: "ProviderStack"),
            .product(name: "HelperCore", package: "HelperPackage"),
            .product(name: "Chat", package: "ChatPackage"),
        ]),
    ]
)
