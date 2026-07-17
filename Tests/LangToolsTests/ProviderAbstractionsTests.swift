import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import LangTools

final class ProviderAbstractionsTests: XCTestCase {
    func testProviderCapabilitiesModelUnsupportedFeaturesExplicitly() {
        let capabilities = ProviderCapabilities(
            runsOnDevice: true,
            supportsStreamingPartials: false,
            supportsContinuousMode: false,
            requiresNetwork: false,
            requiresModelDownload: true
        )

        XCTAssertTrue(capabilities.runsOnDevice)
        XCTAssertFalse(capabilities.supportsStreamingPartials)
        XCTAssertFalse(capabilities.supportsContinuousMode)
        XCTAssertFalse(capabilities.requiresNetwork)
        XCTAssertTrue(capabilities.requiresModelDownload)
    }

    func testProviderIDIsCodableAndHashable() throws {
        let providerID = LangToolsProviderID(rawValue: "local.whisper")
        let encoded = try JSONEncoder().encode(providerID)
        let decoded = try JSONDecoder().decode(LangToolsProviderID.self, from: encoded)

        XCTAssertEqual(decoded, providerID)
        XCTAssertEqual(Set([providerID, decoded]).count, 1)
    }

    func testTranslationRequestUsesBCP47Identifiers() {
        let request = LangToolsTextTranslationRequest(
            text: "Hello",
            sourceLanguageIdentifier: "en-US",
            targetLanguageIdentifier: "es-ES"
        )

        XCTAssertEqual(request.text, "Hello")
        XCTAssertEqual(request.sourceLanguageIdentifier, "en-US")
        XCTAssertEqual(request.targetLanguageIdentifier, "es-ES")
    }

    func testStringConformsToTranscriptionResponse() {
        let response: any LangToolsTranscriptionResponse = "hello world"

        XCTAssertEqual(response.transcriptText, "hello world")
        XCTAssertNil(response.detectedLanguageIdentifier)
    }

    func testDataConformsToAudioResponse() {
        let data = Data([0x01, 0x02, 0x03])
        let response: any LangToolsAudioResponse = data

        XCTAssertEqual(response.audioData, data)
    }

    func testPerformUsesAudioResponseInitializerForRawAudioBytes() async throws {
        let audioData = Data([0x00, 0x01, 0x02, 0x03])
        RawAudioResponseURLProtocol.responseData = audioData
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RawAudioResponseURLProtocol.self]
        let langTool = RawAudioLangTool(session: URLSession(configuration: configuration))

        let response = try await langTool.perform(request: RawAudioRequest())

        XCTAssertEqual(response.audioData, audioData)
        XCTAssertTrue(response.initializedFromAudioData)
    }

    // MARK: - State equality

    func testProviderAuthorizationStateEquality() {
        XCTAssertEqual(ProviderAuthorizationState.authorized, .authorized)
        XCTAssertEqual(ProviderAuthorizationState.denied, .denied)
        XCTAssertEqual(ProviderAuthorizationState.unavailable(reason: "x"), .unavailable(reason: "x"))
        XCTAssertNotEqual(ProviderAuthorizationState.authorized, .denied)
        XCTAssertNotEqual(ProviderAuthorizationState.unavailable(reason: "a"), .unavailable(reason: "b"))
    }

    func testProviderAssetStateEquality() {
        XCTAssertEqual(ProviderAssetState.ready, .ready)
        XCTAssertEqual(ProviderAssetState.failed(reason: "disk full"), .failed(reason: "disk full"))
        XCTAssertNotEqual(ProviderAssetState.ready, .missing)
        XCTAssertNotEqual(ProviderAssetState.failed(reason: "a"), .failed(reason: "b"))
    }

    // MARK: - Generic abstraction boundary

    func testGenericTTSBoundaryAcceptsAnyLangToolsSpeechSynthesisRequest() {
        func speechText(from request: some LangToolsSpeechSynthesisRequest) -> String {
            request.speechText
        }

        struct StubTTS: LangToolsSpeechSynthesisRequest {
            var speechText: String { "stub" }
            var speechVoiceIdentifier: String? { nil }
            var speechSpeed: Double? { nil }
            var speechResponseFormat: String? { nil }
        }

        XCTAssertEqual(speechText(from: StubTTS()), "stub")
    }

    func testGenericSTTBoundaryAcceptsAnyLangToolsSpeechTranscriptionRequest() {
        func audioFormat(from request: some LangToolsSpeechTranscriptionRequest) -> String? {
            request.speechAudioFormat
        }

        struct StubSTT: LangToolsSpeechTranscriptionRequest {
            typealias TranscriptionResponse = String
            var speechAudioData: Data? { nil }
            var speechAudioFileURL: URL? { nil }
            var speechAudioFormat: String? { "wav" }
            var speechLanguageIdentifier: String? { nil }
            var speechPrompt: String? { nil }
        }

        XCTAssertEqual(audioFormat(from: StubSTT()), "wav")
    }

    @MainActor
    func testStreamingSpeechRecognitionProviderExposesStreamingEvents() async throws {
        final class StubStreamingProvider: StreamingSpeechRecognitionProviding {
            let providerID = LangToolsProviderID(rawValue: "stub.streaming")
            let displayName = "Stub Streaming"
            let capabilities = ProviderCapabilities(runsOnDevice: true, supportsStreamingPartials: true)
            let authorizationState: ProviderAuthorizationState = .authorized
            let assetState: ProviderAssetState = .notRequired
            let isAvailable = true
            private(set) var isListening = false
            var isStreaming: Bool { isListening }
            var currentTranscript = ""
            var eventHandler: (@MainActor @Sendable (SpeechRecognitionEvent) -> Void)?

            func configure(languageIdentifier: String) {}
            func requestAuthorization() async -> ProviderAuthorizationState { .authorized }
            func refreshAuthorizationState() {}
            func prepareAssetsIfNeeded() {}
            func startRecognition() throws {}
            func stopRecognition(finalizePending: Bool, clearTranscript: Bool) {}
            func finalizeRecognition() {}

            func transcribe(audioData: Data) async throws -> any LangToolsTranscriptionResponse {
                "bytes: \(audioData.count)"
            }

            func startStreamingRecognition(onEvent: @escaping SpeechRecognitionStreamingEventHandler) async throws {
                isListening = true
                currentTranscript = "hello"
                onEvent(.partialTranscription("hel"))
                onEvent(.finalTranscription("hello"))
            }

            func stopStreamingRecognition() async -> String? {
                isListening = false
                return currentTranscript
            }
        }

        let provider: any StreamingSpeechRecognitionProviding = StubStreamingProvider()
        var events: [SpeechRecognitionEvent] = []

        try await provider.startStreamingRecognition { event in
            events.append(event)
        }
        let finalText = await provider.stopStreamingRecognition()

        XCTAssertEqual(events, [.partialTranscription("hel"), .finalTranscription("hello")])
        XCTAssertEqual(finalText, "hello")
        XCTAssertFalse(provider.isStreaming)
    }

    @MainActor
    func testStreamingSpeechRecognitionProviderCanIngestCapturedAudioChunks() async throws {
        final class StubChunkStreamingProvider: StreamingSpeechRecognitionProviding {
            let providerID = LangToolsProviderID(rawValue: "stub.chunk")
            let displayName = "Stub Chunk"
            let capabilities = ProviderCapabilities(runsOnDevice: false, supportsStreamingPartials: true)
            let authorizationState: ProviderAuthorizationState = .authorized
            let assetState: ProviderAssetState = .notRequired
            let isAvailable = true
            private(set) var isListening = false
            var isStreaming: Bool { isListening }
            let supportsExternalAudioStreaming = true
            var currentTranscript = ""
            var eventHandler: (@MainActor @Sendable (SpeechRecognitionEvent) -> Void)?
            private var streamingEventHandler: SpeechRecognitionStreamingEventHandler?

            func configure(languageIdentifier: String) {}
            func requestAuthorization() async -> ProviderAuthorizationState { .authorized }
            func refreshAuthorizationState() {}
            func prepareAssetsIfNeeded() {}
            func startRecognition() throws {}
            func stopRecognition(finalizePending: Bool, clearTranscript: Bool) {}
            func finalizeRecognition() {}

            func transcribe(audioData: Data) async throws -> any LangToolsTranscriptionResponse {
                "bytes: \(audioData.count)"
            }

            func startStreamingRecognition(onEvent: @escaping SpeechRecognitionStreamingEventHandler) async throws {
                isListening = true
                streamingEventHandler = onEvent
            }

            func appendStreamingAudio(_ audioData: Data) async throws {
                guard isStreaming else { throw StreamingSpeechRecognitionError.notStreaming }
                let text = "bytes: \(audioData.count)"
                currentTranscript = text
                streamingEventHandler?(.partialTranscription(text))
            }

            func stopStreamingRecognition() async -> String? {
                isListening = false
                streamingEventHandler?(.finalTranscription(currentTranscript))
                streamingEventHandler = nil
                return currentTranscript
            }
        }

        let provider: any StreamingSpeechRecognitionProviding = StubChunkStreamingProvider()
        var events: [SpeechRecognitionEvent] = []

        XCTAssertTrue(provider.supportsExternalAudioStreaming)
        try await provider.startStreamingRecognition { event in
            events.append(event)
        }
        try await provider.appendStreamingAudio(Data([1, 2]))
        try await provider.appendStreamingAudio(Data([1, 2, 3]))
        let finalText = await provider.stopStreamingRecognition()

        XCTAssertEqual(events, [
            .partialTranscription("bytes: 2"),
            .partialTranscription("bytes: 3"),
            .finalTranscription("bytes: 3")
        ])
        XCTAssertEqual(finalText, "bytes: 3")
        XCTAssertFalse(provider.isStreaming)
    }

    @MainActor
    func testStreamingProviderDefaultRejectsExternalAudio() async throws {
        final class NativeOnlyStreamingProvider: StreamingSpeechRecognitionProviding {
            let providerID = LangToolsProviderID(rawValue: "stub.native")
            let displayName = "Stub Native"
            let capabilities = ProviderCapabilities(runsOnDevice: true, supportsStreamingPartials: true)
            let authorizationState: ProviderAuthorizationState = .authorized
            let assetState: ProviderAssetState = .notRequired
            let isAvailable = true
            private(set) var isListening = false
            var isStreaming: Bool { isListening }
            var currentTranscript = ""
            var eventHandler: (@MainActor @Sendable (SpeechRecognitionEvent) -> Void)?

            func configure(languageIdentifier: String) {}
            func requestAuthorization() async -> ProviderAuthorizationState { .authorized }
            func refreshAuthorizationState() {}
            func prepareAssetsIfNeeded() {}
            func startRecognition() throws {}
            func stopRecognition(finalizePending: Bool, clearTranscript: Bool) {}
            func finalizeRecognition() {}

            func transcribe(audioData: Data) async throws -> any LangToolsTranscriptionResponse {
                "native"
            }

            func startStreamingRecognition(onEvent: @escaping SpeechRecognitionStreamingEventHandler) async throws {
                isListening = true
            }

            func stopStreamingRecognition() async -> String? {
                isListening = false
                return nil
            }
        }

        let provider: any StreamingSpeechRecognitionProviding = NativeOnlyStreamingProvider()

        XCTAssertFalse(provider.supportsExternalAudioStreaming)
        do {
            try await provider.appendStreamingAudio(Data([1]))
            XCTFail("Expected external audio ingestion to be unsupported")
        } catch let error as StreamingSpeechRecognitionError {
            XCTAssertEqual(error, .externalAudioUnsupported)
        }
    }

    @MainActor
    func testSpeechRecognitionProviderAcceptsCapturedAudio() async throws {
        final class StubProvider: SpeechRecognitionProviding {
            let providerID = LangToolsProviderID(rawValue: "stub.audio")
            let displayName = "Stub Audio"
            let capabilities = ProviderCapabilities(runsOnDevice: true)
            let authorizationState: ProviderAuthorizationState = .authorized
            let assetState: ProviderAssetState = .notRequired
            let isAvailable = true
            let isListening = false
            var currentTranscript = ""
            var eventHandler: (@MainActor @Sendable (SpeechRecognitionEvent) -> Void)?

            func configure(languageIdentifier: String) {}
            func requestAuthorization() async -> ProviderAuthorizationState { .authorized }
            func refreshAuthorizationState() {}
            func prepareAssetsIfNeeded() {}
            func startRecognition() throws {}
            func stopRecognition(finalizePending: Bool, clearTranscript: Bool) {}
            func finalizeRecognition() {}

            func transcribe(audioData: Data) async throws -> any LangToolsTranscriptionResponse {
                "bytes: \(audioData.count)"
            }
        }

        let provider: any SpeechRecognitionProviding = StubProvider()
        let response = try await provider.transcribe(audioData: Data([1, 2, 3]))

        XCTAssertEqual(response.transcriptText, "bytes: 3")
    }
}

private struct RawAudioResponse: Decodable, LangToolsAudioResponse {
    let audioData: Data
    let initializedFromAudioData: Bool

    init(audioData: Data) throws {
        self.audioData = audioData
        initializedFromAudioData = true
    }

    init(from decoder: Decoder) throws {
        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "Raw audio bytes are not JSON-decodable")
        )
    }
}

private struct RawAudioRequest: LangToolsRequest {
    typealias LangTool = RawAudioLangTool
    typealias Response = RawAudioResponse

    static let endpoint = "audio"
}

private enum RawAudioModel: String {
    case mock
}

private struct RawAudioErrorResponse: Codable, Error {}

private struct RawAudioLangTool: LangTools {
    typealias Model = RawAudioModel
    typealias ErrorResponse = RawAudioErrorResponse

    static let requestValidators: [(any LangToolsRequest) -> Bool] = [{ $0 is RawAudioRequest }]
    let session: URLSession

    static func chatRequest(
        model: any RawRepresentable,
        messages: [any LangToolsMessage],
        tools: [any LangToolsTool]?,
        responseSchema: JSONSchema?,
        toolEventHandler: @escaping (LangToolsToolEvent) -> Void
    ) throws -> any LangToolsChatRequest {
        throw LangToolsError.invalidArgument("RawAudioLangTool does not support chat requests")
    }

    func prepare(request: some LangToolsRequest) throws -> URLRequest {
        URLRequest(url: URL(string: "https://example.com/audio")!)
    }
}

private final class RawAudioResponseURLProtocol: URLProtocol {
    static var responseData = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
