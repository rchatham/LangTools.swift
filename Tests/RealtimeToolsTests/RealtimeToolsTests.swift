//
//  RealtimeToolsTests.swift
//  LangTools
//
//  Created by Reid Chatham on 1/16/26.
//

import XCTest
@testable import RealtimeTools
@testable import LangTools

final class RealtimeToolsTests: XCTestCase {

    // MARK: - Pipeline Configuration Tests

    func testPipelineConfigurationDefaults() {
        let config = RealtimePipelineConfiguration()

        XCTAssertNil(config.sttProvider)
        XCTAssertNil(config.ttsProvider)
        XCTAssertNil(config.llmProvider)
        XCTAssertEqual(config.mode, .speechToSpeech)
    }

    func testPipelineConfigurationModes() {
        XCTAssertEqual(RealtimePipelineConfiguration.PipelineMode.speechToSpeech.rawValue, "speechToSpeech")
        XCTAssertEqual(RealtimePipelineConfiguration.PipelineMode.modular.rawValue, "modular")
        XCTAssertEqual(RealtimePipelineConfiguration.PipelineMode.transcriptionOnly.rawValue, "transcriptionOnly")
        XCTAssertEqual(RealtimePipelineConfiguration.PipelineMode.speechOnly.rawValue, "speechOnly")
    }

    // MARK: - STT Provider Configuration Tests

    func testSTTProviderConfiguration() {
        let config = STTProviderConfiguration(
            provider: .appleOnDevice,
            language: "en-US",
            enableInterimResults: true
        )

        XCTAssertEqual(config.provider, .appleOnDevice)
        XCTAssertEqual(config.language, "en-US")
        XCTAssertTrue(config.enableInterimResults)
    }

    func testSTTProviderTypes() {
        XCTAssertEqual(STTProviderConfiguration.STTProvider.appleOnDevice.rawValue, "apple_on_device")
        XCTAssertEqual(STTProviderConfiguration.STTProvider.openAIWhisper.rawValue, "openai_whisper")
        XCTAssertEqual(STTProviderConfiguration.STTProvider.openAIRealtime.rawValue, "openai_realtime")
        XCTAssertEqual(STTProviderConfiguration.STTProvider.elevenLabsScribe.rawValue, "elevenlabs_scribe")
    }

    // MARK: - TTS Provider Configuration Tests

    func testTTSProviderConfiguration() {
        let config = TTSProviderConfiguration(
            provider: .elevenLabs,
            voice: "test-voice",
            model: "eleven_flash_v2_5",
            speed: 1.2
        )

        XCTAssertEqual(config.provider, .elevenLabs)
        XCTAssertEqual(config.voice, "test-voice")
        XCTAssertEqual(config.model, "eleven_flash_v2_5")
        XCTAssertEqual(config.speed, 1.2)
    }

    func testTTSOutputFormatSampleRates() {
        XCTAssertEqual(TTSProviderConfiguration.TTSOutputFormat.pcm16_24000.sampleRate, 24000)
        XCTAssertEqual(TTSProviderConfiguration.TTSOutputFormat.pcm16_16000.sampleRate, 16000)
        XCTAssertEqual(TTSProviderConfiguration.TTSOutputFormat.mp3_192.sampleRate, 44100)
    }

    func testTTSOutputFormatIsPCM() {
        XCTAssertTrue(TTSProviderConfiguration.TTSOutputFormat.pcm16_24000.isPCM)
        XCTAssertFalse(TTSProviderConfiguration.TTSOutputFormat.mp3_128.isPCM)
        XCTAssertFalse(TTSProviderConfiguration.TTSOutputFormat.opus.isPCM)
    }

    // MARK: - LLM Provider Configuration Tests

    func testLLMProviderConfiguration() {
        let config = LLMProviderConfiguration(
            provider: .openAI,
            model: "gpt-4o",
            systemPrompt: "You are a helpful assistant",
            temperature: 0.7
        )

        XCTAssertEqual(config.provider, .openAI)
        XCTAssertEqual(config.model, "gpt-4o")
        XCTAssertEqual(config.systemPrompt, "You are a helpful assistant")
        XCTAssertEqual(config.temperature, 0.7)
    }

    // MARK: - Audio Processing Settings Tests

    func testAudioProcessingSettingsDefaults() {
        let settings = AudioProcessingSettings.default

        XCTAssertEqual(settings.inputSampleRate, 16000)
        XCTAssertEqual(settings.outputSampleRate, 24000)
        XCTAssertEqual(settings.channels, 1)
        XCTAssertEqual(settings.bitsPerSample, 16)
        XCTAssertTrue(settings.echoCancellation)
        XCTAssertTrue(settings.noiseSuppression)
    }

    func testAudioProcessingSettingsOpenAIPreset() {
        let settings = AudioProcessingSettings.openAIRealtime

        XCTAssertEqual(settings.inputSampleRate, 24000)
        XCTAssertEqual(settings.outputSampleRate, 24000)
    }

    func testAudioProcessingSettingsElevenLabsPreset() {
        let settings = AudioProcessingSettings.elevenLabs

        XCTAssertEqual(settings.inputSampleRate, 16000)
        XCTAssertEqual(settings.outputSampleRate, 22050)
    }

    // MARK: - VAD Configuration Tests

    func testVADConfigurationDefaults() {
        let config = VADConfiguration()

        XCTAssertEqual(config.mode, .automatic)
        XCTAssertEqual(config.threshold, 0.5)
        XCTAssertEqual(config.silenceTimeout, 0.5)
    }

    func testVADModes() {
        XCTAssertEqual(VADConfiguration.VADMode.server.rawValue, "server")
        XCTAssertEqual(VADConfiguration.VADMode.onDevice.rawValue, "onDevice")
        XCTAssertEqual(VADConfiguration.VADMode.automatic.rawValue, "automatic")
        XCTAssertEqual(VADConfiguration.VADMode.manual.rawValue, "manual")
    }

    // MARK: - Interruption Configuration Tests

    func testInterruptionConfigurationDefaults() {
        let config = InterruptionConfiguration()

        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.mode, .immediate)
        XCTAssertEqual(config.minPlaybackBeforeInterrupt, 0.5)
    }

    func testInterruptionModes() {
        XCTAssertEqual(InterruptionConfiguration.InterruptionMode.immediate.rawValue, "immediate")
        XCTAssertEqual(InterruptionConfiguration.InterruptionMode.fadeOut.rawValue, "fadeOut")
        XCTAssertEqual(InterruptionConfiguration.InterruptionMode.queued.rawValue, "queued")
        XCTAssertEqual(InterruptionConfiguration.InterruptionMode.sentenceBoundary.rawValue, "sentenceBoundary")
    }

    // MARK: - Pipeline Builder Tests

    func testPipelineBuilderBasic() {
        let pipeline = RealtimePipelineBuilder()
            .withMode(.transcriptionOnly)
            .withSTT(STTProviderConfiguration(provider: .appleOnDevice))
            .build()

        XCTAssertEqual(pipeline.configuration.mode, .transcriptionOnly)
        XCTAssertEqual(pipeline.configuration.sttProvider?.provider, .appleOnDevice)
    }

    func testPipelineBuilderOpenAIPreset() {
        let pipeline = RealtimePipelineBuilder.openAIRealtime().build()

        XCTAssertEqual(pipeline.configuration.mode, .speechToSpeech)
        XCTAssertEqual(pipeline.configuration.audioSettings.inputSampleRate, 24000)
        XCTAssertTrue(pipeline.interruptionConfig.enabled)
    }

    func testPipelineBuilderTranscriptionOnlyPreset() {
        let pipeline = RealtimePipelineBuilder.transcriptionOnly().build()

        XCTAssertEqual(pipeline.configuration.mode, .transcriptionOnly)
        XCTAssertEqual(pipeline.configuration.sttProvider?.provider, .appleOnDevice)
    }

    // MARK: - Pipeline State Tests

    func testPipelineInitialState() {
        let pipeline = RealtimePipelineBuilder().build()
        XCTAssertEqual(pipeline.state, .idle)
    }

    // MARK: - Transcription Result Tests

    func testTranscriptionResult() {
        let result = TranscriptionResult(
            text: "Hello world",
            isFinal: true,
            confidence: 0.95,
            words: [
                TranscriptionResult.WordTiming(word: "Hello", start: 0.0, end: 0.5),
                TranscriptionResult.WordTiming(word: "world", start: 0.5, end: 1.0)
            ],
            language: "en-US"
        )

        XCTAssertEqual(result.text, "Hello world")
        XCTAssertTrue(result.isFinal)
        XCTAssertEqual(result.confidence, 0.95)
        XCTAssertEqual(result.words?.count, 2)
        XCTAssertEqual(result.language, "en-US")
    }

    // MARK: - VAD Result Tests

    func testVADResult() {
        let result = VADResult(
            isSpeech: true,
            probability: 0.85,
            timestamp: 1.5
        )

        XCTAssertTrue(result.isSpeech)
        XCTAssertEqual(result.probability, 0.85)
        XCTAssertEqual(result.timestamp, 1.5)
    }

    // MARK: - Pipeline Error Tests

    func testPipelineErrorDescriptions() {
        XCTAssertNotNil(RealtimePipelineError.notRunning.errorDescription)
        XCTAssertNotNil(RealtimePipelineError.alreadyRunning.errorDescription)
        XCTAssertNotNil(RealtimePipelineError.providerNotConfigured("TTS").errorDescription)
        XCTAssertNotNil(RealtimePipelineError.invalidModeForOperation.errorDescription)
    }
}
