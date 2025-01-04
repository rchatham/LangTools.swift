//
//  OpenAI+AudioSpeechRequest.swift
//  LangTools
//
//  Created by Reid Chatham on 11/17/24.
//  Adapted from AudioSpeechQuery.swift - Created by Ihor Makhnyk on 13.11.2023.
//

import Foundation
import LangTools

extension OpenAI {
    /// Generates audio from the input text.
    /// Learn more: [OpenAI Speech – Documentation](https://platform.openai.com/docs/api-reference/audio/createSpeech)
    public struct AudioSpeechRequest: Codable, LangToolsRequest, LangToolsTTSRequest {
        public typealias LangTool = OpenAI
        public static var endpoint: String { "audio/speech" }

        /// The text to generate audio for. The maximum length is 4096 characters.
        public let input: String
        /// One of the available TTS models: tts-1 or tts-1-hd
        public let model: Model
        /// The voice to use when generating the audio. Supported voices are alloy, echo, fable, onyx, nova, and shimmer. Previews of the voices are available in the Text to speech guide.
        /// https://platform.openai.com/docs/guides/text-to-speech/voice-options
        public let voice: AudioSpeechVoice
        /// The format to audio in. Supported formats are mp3, opus, aac, and flac.
        /// Defaults to mp3
        public let responseFormat: AudioSpeechResponseFormat?
        /// The speed of the generated audio. Select a value from **0.25** to **4.0**. **1.0** is the default.
        /// Defaults to 1
        public let speed: String?

        public enum CodingKeys: String, CodingKey {
            case model
            case input
            case voice
            case responseFormat = "response_format"
            case speed
        }

        public init(model: Model, input: String, voice: AudioSpeechVoice, responseFormat: AudioSpeechResponseFormat = .mp3, speed: Double?) {
            self.model = AudioSpeechRequest.validateSpeechModel(model)
            self.speed = AudioSpeechRequest.normalizeSpeechSpeed(speed)
            self.input = input
            self.voice = voice
            self.responseFormat = responseFormat
        }

        /// Encapsulates the voices available for audio generation.
        ///
        /// To get aquinted with each of the voices and listen to the samples visit:
        /// [OpenAI Text-to-Speech – Voice Options](https://platform.openai.com/docs/guides/text-to-speech/voice-options)
        public enum AudioSpeechVoice: String, Codable, CaseIterable {
            case alloy
            case echo
            case fable
            case onyx
            case nova
            case shimmer
        }

        /// Encapsulates the response formats available for audio data.
        ///
        /// **Formats:**
        /// -  mp3
        /// -  opus
        /// -  aac
        /// -  flac
        public enum AudioSpeechResponseFormat: String, Codable, CaseIterable {
            case mp3
            case opus
            case aac
            case flac
        }
    }
}

private extension OpenAI.AudioSpeechRequest {
    static func validateSpeechModel(_ inputModel: OpenAI.Model) -> OpenAI.Model {
        guard [.tts_1, .tts_1_hd].contains(inputModel) else {
            print("[AudioSpeech] 'AudioSpeechQuery' must have a valid Text-To-Speech model, 'tts-1' or 'tts-1-hd'. Setting model to 'tts-1'.")
            return .tts_1
        }
        return inputModel
    }
}

public extension OpenAI.AudioSpeechRequest {
    enum Speed: Double {
        case normal = 1.0
        case max = 4.0
        case min = 0.25
    }

    static func normalizeSpeechSpeed(_ inputSpeed: Double?) -> String {
        guard let inputSpeed else { return "\(Self.Speed.normal.rawValue)" }
        let isSpeedOutOfBounds = inputSpeed <= Self.Speed.min.rawValue || Self.Speed.max.rawValue <= inputSpeed
        guard !isSpeedOutOfBounds else {
            print("[AudioSpeech] Speed value must be between 0.25 and 4.0. Setting value to closest valid.")
            return inputSpeed < Self.Speed.min.rawValue ? "\(Self.Speed.min.rawValue)" : "\(Self.Speed.max.rawValue)"
        }
        return "\(inputSpeed)"
    }
}
