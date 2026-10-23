import AppleLangTools
import KeychainAccess
import LangTools
import XCTest
@testable import Chat

final class AppleIntelligenceRouteTests: XCTestCase {
    func testAppleModelRoundTripsThroughRawValue() {
        let model = Model.apple(.onDevice)
        XCTAssertEqual(model.rawValue, "apple/on-device")
        XCTAssertEqual(Model(rawValue: "apple/on-device"), model)
        XCTAssertEqual(model.apiService, .apple)
        XCTAssertNil(AccessDestination.destination(for: model))
    }

    func testAppleModelsAreListedOnlyWhereFoundationModelsShips() {
        XCTAssertEqual(Model.appleModels.isEmpty, !AppleIntelligence.isSupportedOnThisOS)
        XCTAssertEqual(Model.chatModels.contains(.apple(.onDevice)), AppleIntelligence.isSupportedOnThisOS)
    }

    func testRequestMapsGenerationSettingsToAppleOptions() throws {
        let keychain = Keychain(service: "AppleIntelligenceRouteTests.\(UUID().uuidString)")
        defer { try? keychain.removeAll() }
        let keychainService = KeychainService(keychain: keychain)
        let client = NetworkClient(
            keychainService: keychainService,
            providerAccessManager: ProviderAccessManager(keychainService: keychainService, sessionStore: AuthSessionStore(keychain: keychain))
        )
        let settings = try ChatGenerationSettings(maxOutputTokens: 512, temperature: 0.3, topK: 40, seed: 7)

        let request = client.request(
            messages: [Message(text: "Be brief.", role: .system), Message(text: "Hi", role: .user)],
            model: .apple(.onDevice),
            generationSettings: settings,
            stream: true
        )

        let appleRequest = try XCTUnwrap(request as? AppleIntelligence.ChatRequest)
        XCTAssertEqual(appleRequest.temperature, 0.3)
        XCTAssertEqual(appleRequest.maximumResponseTokens, 512)
        XCTAssertEqual(appleRequest.sampling, .topK(40, seed: 7))
        XCTAssertEqual(appleRequest.stream, true)
        XCTAssertEqual(appleRequest.messages.map(\.content.text), ["Be brief.", "Hi"])
    }
}
