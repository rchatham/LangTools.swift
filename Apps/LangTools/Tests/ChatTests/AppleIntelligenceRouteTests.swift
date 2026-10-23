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

    func testAppleModelGetsItsOwnPickerGroup() {
        XCTAssertEqual(Model.apple(.onDevice).providerDisplayName, "Apple Intelligence")
        XCTAssertEqual(Model.pickerGroups([.apple(.onDevice)]).map(\.title), ["Apple Intelligence"])
    }

    func testAppleModelsAreListedOnlyWhereFoundationModelsShips() {
        XCTAssertEqual(Model.appleModels.isEmpty, !AppleIntelligence.isSupportedOnThisOS)
        XCTAssertEqual(Model.chatModels.contains(.apple(.onDevice)), AppleIntelligence.isSupportedOnThisOS)
    }

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
        let request = client.request(messages: messages, model: .apple(.onDevice), generationSettings: settings, stream: true)
        return try XCTUnwrap(request as? AppleIntelligence.ChatRequest)
    }

    func testRequestMapsGenerationSettingsToAppleOptions() throws {
        let request = try appleRequest(
            try ChatGenerationSettings(maxOutputTokens: 512, temperature: 0.3, topK: 40, seed: 7),
            messages: [Message(text: "Be brief.", role: .system), Message(text: "Hi", role: .user)]
        )

        XCTAssertEqual(request.temperature, 0.3)
        XCTAssertEqual(request.maximumResponseTokens, 512)
        XCTAssertEqual(request.sampling, .topK(40, seed: 7))
        XCTAssertEqual(request.stream, true)
        XCTAssertEqual(request.messages.map(\.content.text), ["Be brief.", "Hi"])
    }

    func testTopPMapsToProbabilitySamplingAndTopKTakesPrecedence() throws {
        XCTAssertEqual(try appleRequest(try ChatGenerationSettings(topP: 0.9, seed: 3)).sampling, .topP(0.9, seed: 3))
        XCTAssertEqual(try appleRequest(try ChatGenerationSettings(topP: 0.9, topK: 20)).sampling, .topK(20, seed: nil))
    }

    func testTemperatureOnlyLeavesSamplingAndTokenCapUnset() throws {
        let request = try appleRequest(try ChatGenerationSettings(temperature: 0.7))
        XCTAssertEqual(request.temperature, 0.7)
        XCTAssertNil(request.sampling)
        XCTAssertNil(request.maximumResponseTokens)
    }

    func testTokenCapAboveContextWindowIsNotForwarded() throws {
        let request = try appleRequest(try ChatGenerationSettings(maxOutputTokens: AppleIntelligence.Model.contextWindowTokens + 1))
        XCTAssertNil(request.maximumResponseTokens)
    }

    func testToolMessagesAreNotReplayed() {
        let messages = [Message(text: "Hi", role: .user), Message(text: "{\"ok\":true}", role: .tool)].toAppleIntelligenceMessages()
        XCTAssertEqual(messages.map(\.content.text), ["Hi"])
    }

    func testAgentContextRejectsAppleRouteAsToolCallingUnsupported() {
        XCTAssertThrowsError(try client.agentContext(messages: [Message(text: "Hi", role: .user)], model: .apple(.onDevice), eventHandler: { _ in })) {
            XCTAssertEqual($0 as? AppleIntelligenceError, .toolCallingUnsupported)
        }
    }

    func testRequestsFailWithAvailabilityReasonWhenModelIsUnavailable() async throws {
        guard case .unavailable(let reason) = AppleIntelligence.availability() else {
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
