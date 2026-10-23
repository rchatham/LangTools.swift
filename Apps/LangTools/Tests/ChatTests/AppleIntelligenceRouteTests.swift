import AppleLangTools
import KeychainAccess
import XCTest
@testable import Chat

final class AppleIntelligenceRouteTests: XCTestCase {
    private var keychain: Keychain!
    private var client: NetworkClient!

    override func setUp() {
        super.setUp()
        keychain = Keychain(service: "AppleIntelligenceRouteTests.\(UUID().uuidString)")
        let keychainService = KeychainService(keychain: keychain)
        client = NetworkClient(
            keychainService: keychainService,
            providerAccessManager: ProviderAccessManager(keychainService: keychainService, sessionStore: AuthSessionStore(keychain: keychain))
        )
    }

    override func tearDown() {
        try? keychain.removeAll()
        super.tearDown()
    }

    private func appleRequest(_ settings: ChatGenerationSettings, messages: [Message] = [Message(text: "Hi", role: .user)]) throws -> AppleIntelligence.ChatRequest {
        try XCTUnwrap(client.request(messages: messages, model: .apple(.onDevice), generationSettings: settings, stream: true) as? AppleIntelligence.ChatRequest)
    }

    func testAppleModelRouteAndPickerGroup() {
        let model = Model.apple(.onDevice)
        XCTAssertEqual(model.rawValue, "apple/on-device")
        XCTAssertEqual(Model(rawValue: "apple/on-device"), model)
        XCTAssertNil(AccessDestination.destination(for: model))
        XCTAssertEqual(Model.pickerGroups([model]).map(\.title), ["Apple Intelligence"])
    }

    func testRequestMapsGenerationSettings() throws {
        let request = try appleRequest(
            try ChatGenerationSettings(maxOutputTokens: 512, temperature: 0.3, topK: 40, seed: 7),
            messages: [Message(text: "Be brief.", role: .system), Message(text: "Hi", role: .user), Message(text: "{}", role: .tool)]
        )
        XCTAssertEqual(request.temperature, 0.3)
        XCTAssertEqual(request.maximumResponseTokens, 512)
        XCTAssertEqual(request.sampling, .topK(40, seed: 7))
        XCTAssertEqual(request.messages.map(\.content.text), ["Be brief.", "Hi"])

        // GenerationOptions takes one sampling mode: top-p applies only without top-k.
        XCTAssertEqual(try appleRequest(try ChatGenerationSettings(topP: 0.9, seed: 3)).sampling, .topP(0.9, seed: 3))
        XCTAssertEqual(try appleRequest(try ChatGenerationSettings(topP: 0.9, topK: 20)).sampling, .topK(20, seed: nil))
        XCTAssertNil(try appleRequest(try ChatGenerationSettings(temperature: 0.7)).sampling)
    }

    func testAgentRunsAreRejected() {
        XCTAssertThrowsError(try client.agentContext(messages: [Message(text: "Hi", role: .user)], model: .apple(.onDevice), eventHandler: { _ in })) {
            XCTAssertEqual($0 as? AppleIntelligenceError, .toolCallingUnsupported)
        }
    }

    func testUnavailableModelFailsWithItsReason() async throws {
        guard case .unavailable(let reason) = AppleIntelligence.availability else {
            throw XCTSkip("Apple Intelligence is available here")
        }
        do {
            _ = try await client.performChatCompletionRequest(messages: [Message(text: "Hi", role: .user)], model: .apple(.onDevice), tools: nil, toolChoice: nil)
            XCTFail("Expected an availability error")
        } catch {
            XCTAssertEqual(error as? AppleIntelligenceError, .unavailable(reason))
            XCTAssertTrue(error.isAppleIntelligenceError)
        }
    }
}
