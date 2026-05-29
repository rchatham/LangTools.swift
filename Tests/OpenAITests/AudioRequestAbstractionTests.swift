import XCTest
import LangTools
@testable import OpenAI

final class AudioRequestAbstractionTests: XCTestCase {
    func testAudioSpeechRequestExposesGenericTTSShape() {
        let request = OpenAI.AudioSpeechRequest(
            model: .tts_1,
            input: "Hello",
            voice: .alloy,
            responseFormat: .mp3,
            speed: 1.25
        )

        let genericRequest: any LangToolsTTSRequest = request
        XCTAssertEqual(genericRequest.speechText, "Hello")
        XCTAssertEqual(genericRequest.speechVoiceIdentifier, "alloy")
        XCTAssertEqual(genericRequest.speechSpeed, 1.25)
        XCTAssertEqual(genericRequest.speechResponseFormat, "mp3")
    }

    func testAudioTranscriptionRequestExposesGenericSTTShape() {
        let audio = Data([0x01, 0x02])
        let request = OpenAI.AudioTranscriptionRequest(
            file: audio,
            fileType: .wav,
            prompt: "names: Hermes",
            language: "en"
        )

        let genericRequest: any LangToolsSTTRequest = request
        XCTAssertEqual(genericRequest.speechAudioData, audio)
        XCTAssertNil(genericRequest.speechAudioFileURL)
        XCTAssertEqual(genericRequest.speechAudioFormat, "wav")
        XCTAssertEqual(genericRequest.speechLanguageIdentifier, "en")
        XCTAssertEqual(genericRequest.speechPrompt, "names: Hermes")
    }

    func testAudioTranscriptionResponseExposesGenericText() {
        let response = OpenAI.AudioTranscriptionRequest.AudioTranscriptionResponse(
            task: "transcribe",
            language: "en",
            duration: 1.0,
            text: "Hello",
            words: nil,
            segments: nil
        )

        let genericResponse: any LangToolsTranscriptionResponse = response
        XCTAssertEqual(genericResponse.transcriptText, "Hello")
        XCTAssertEqual(genericResponse.detectedLanguageIdentifier, "en")
    }
}
