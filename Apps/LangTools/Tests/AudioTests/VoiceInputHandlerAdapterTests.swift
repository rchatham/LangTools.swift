import Combine
import Foundation
import XCTest
@testable import Audio

@MainActor
final class VoiceInputHandlerAdapterTests: XCTestCase {
    func testInactiveAdapterNeverReadsSettingsOrReactivatesAfterActionsAndSettingsChanges() async {
        // STTService's private initializer is empty. Never register providers or
        // construct the default-enabled adapter in this privacy regression.
        let service = STTService.shared
        let settings = ReadTrackingVoiceInputSettings()
        XCTAssertNil(service.currentProvider)
        XCTAssertEqual(service.status, .idle)

        let adapter = VoiceInputHandlerAdapter(
            sttService: service,
            settings: settings,
            startupRealProvidersEnabled: false
        )

        let assertInactive = {
            XCTAssertFalse(adapter.isEnabled)
            XCTAssertFalse(adapter.isRecording)
            XCTAssertFalse(adapter.isProcessing)
            XCTAssertFalse(adapter.replaceSendButton)
            XCTAssertEqual(adapter.audioLevel, 0)
            XCTAssertEqual(adapter.statusDescription, "Voice input disabled")
            XCTAssertNil(adapter.getTranscribedText())
            XCTAssertEqual(adapter.partialText, "")
            XCTAssertEqual(adapter.whisperKitLoadingState, .idle)
            XCTAssertNil(adapter.pendingTranscribedText)

            XCTAssertNil(service.currentProvider)
            XCTAssertFalse(service.isAvailable)
            XCTAssertFalse(service.isRecording)
            XCTAssertFalse(service.isProcessing)
            XCTAssertEqual(service.status, .idle)
            XCTAssertNil(service.error)
            XCTAssertEqual(service.transcribedText, "")
            XCTAssertEqual(service.partialTranscription, "")
            XCTAssertEqual(service.whisperKitLoadingState, .idle)
            // Includes settingsDidChange: zero reads proves no subscription
            // was installed, so emitted changes cannot schedule reactivation.
            XCTAssertEqual(settings.readProperties, [])
        }

        assertInactive()
        adapter.preloadWhisperKit()
        assertInactive()
        adapter.cancelRecording()
        assertInactive()
        await adapter.toggleRecording()
        assertInactive()

        // Each provider selection advertises enabled input and replacement of
        // the send button. None may override the startup lifetime suppression.
        for providerType in STTProviderType.allCases {
            settings.selectedProvider = providerType
            settings.changes.send(())
            assertInactive()
            await adapter.toggleRecording()
            assertInactive()
            adapter.cancelRecording()
            assertInactive()
            adapter.preloadWhisperKit()
            assertInactive()
        }
    }

    @MainActor
    private final class ReadTrackingVoiceInputSettings: VoiceInputSettingsProviding {
        private(set) var readProperties: [String] = []
        var selectedProvider: STTProviderType = .whisperKit
        let changes = PassthroughSubject<Void, Never>()

        var voiceInputEnabled: Bool {
            readProperties.append(#function)
            return true
        }

        var sttProviderType: STTProviderType {
            readProperties.append(#function)
            return selectedProvider
        }

        var voiceButtonReplaceSend: Bool {
            readProperties.append(#function)
            return true
        }

        var sttLanguageIdentifier: String? {
            readProperties.append(#function)
            return "en-US"
        }

        var whisperKitModelVariant: String {
            readProperties.append(#function)
            return "base"
        }

        var enableOpenAISimulatedStreaming: Bool {
            readProperties.append(#function)
            return true
        }

        var openAIStreamingChunkInterval: TimeInterval {
            readProperties.append(#function)
            return 3.0
        }

        var openAIApiKey: String? {
            readProperties.append(#function)
            return nil
        }

        var settingsDidChange: AnyPublisher<Void, Never> {
            readProperties.append(#function)
            return changes.eraseToAnyPublisher()
        }
    }
}
