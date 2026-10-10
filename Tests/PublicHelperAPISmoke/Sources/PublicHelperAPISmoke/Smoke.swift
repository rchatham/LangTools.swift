import Foundation
import SwiftUI
import HelperLink
import HelperCore
import Chat
import Ollama

/// Compile-only consumer: no @testable access and no executable entry point.
/// Building this package must never run configuration, Keychain or network code.
public enum PublicHelperAPISmoke {
    public typealias SharedRelay = MobileOllamaServer

    @MainActor
    public static func compileClientSurface() throws -> some View {
        let payload = MobileHelperPairingPayload(
            endpoint: URL(string: "https://192.168.1.20:8087")!,
            helperID: UUID().uuidString,
            fingerprint: String(repeating: "a", count: 64),
            code: String(repeating: "b", count: 64), name: "Fixture Mac"
        )
        let legacyParser: (URL) throws -> MobileHelperPairingPayload = MobileHelperPairingPayload.parse
        let legacyURL: () throws -> URL = payload.pairingURL
        _ = try legacyParser(legacyURL())
        let configuredURL = try payload.pairingURL(scheme: "botsworth")
        _ = try MobileHelperPairingPayload.parse(configuredURL, scheme: "botsworth")

        let defaults = UserDefaults(suiteName: "PublicHelperAPISmoke.\(UUID().uuidString)")!
        let configuration = try OllamaEndpointConfiguration(
            userDefaults: defaults, keychainService: "PublicHelperAPISmoke.devices"
        )
        let session = URLSession(configuration: .ephemeral)
        let provider: Ollama = try configuration.snapshot().provider(directSession: session)
        _ = provider
        let legacyCoordinator: () -> MobileHelperPairingCoordinator = MobileHelperPairingCoordinator.init
        _ = legacyCoordinator
        let coordinator = try MobileHelperPairingCoordinator(
            configuration: configuration, scheme: "botsworth", didSelect: {}
        )
        let legacyClassifier: (URL) -> Bool = MobileHelperPairingCoordinator.isPairingURL
        let configuredClassifier: (URL, String) -> Bool = MobileHelperPairingCoordinator.isPairingURL
        _ = legacyClassifier(configuredURL)
        _ = configuredClassifier(configuredURL, "botsworth")
        _ = EmptyView().mobileHelperPairingPresentation()
        return EmptyView().mobileHelperPairingPresentation(
            coordinator: coordinator, brandingTitle: "Connect Botsworth Helper"
        )
    }
}
