//
//  OpenAI+AudioTranscriptionRequest.swift
//  LangTools
//
//  Created by Reid Chatham on 12/21/24.
//  Adapted from AudioTranscriptionQuery.swift - Created by Sergii Kryvoblotskyi on 02/04/2023.
//

import Foundation
import LangTools

extension OpenAI {
    public struct AudioTranscriptionRequest: LangToolsRequest {
        public typealias Response = AudioTranscriptionResponse
        public typealias LangTool = OpenAI
        public static var endpoint: String { "audio/transcriptions" }

        public enum ResponseFormat: String, Codable, Equatable, CaseIterable {
            case json, text, srt, vtt
            case verboseJson = "verbose_json"
        }

        /// The audio file object (not file name) to transcribe, in one of these formats: flac, mp3, mp4, mpeg, mpga, m4a, ogg, wav, or webm.
        public let file: Data
        public let fileType: FileType
        /// ID of the model to use. Only whisper-1 is currently available.
        public let model: Model = .whisper
        /// The format of the transcript output, in one of these options: json, text, srt, verbose_json, or vtt.
        /// Defaults to json
        public let responseFormat: ResponseFormat?
        /// An optional text to guide the model's style or continue a previous audio segment. The prompt should match the audio language.
        public let prompt: String?
        /// The sampling temperature, between 0 and 1. Higher values like 0.8 will make the output more random, while lower values like 0.2 will make it more focused and deterministic. If set to 0, the model will use log probability to automatically increase the temperature until certain thresholds are hit.
        /// Defaults to 0
        public let temperature: Double?
        /// The language of the input audio. Supplying the input language in ISO-639-1 format will improve accuracy and latency.
        /// https://platform.openai.com/docs/guides/speech-to-text/prompting
        public let language: String?

        public let timestamp_granularities: [TimestampGranularity]?

        public init(file: Data, fileType: FileType, prompt: String? = nil, temperature: Double? = nil, language: String? = nil, responseFormat: ResponseFormat? = nil, timestamp_granularities: [TimestampGranularity]? = nil) {
            self.file = file
            self.fileType = fileType
            self.prompt = prompt
            self.temperature = temperature
            self.language = language
            self.responseFormat = responseFormat
            self.timestamp_granularities = timestamp_granularities
        }

        public enum TimestampGranularity: String, Codable { // Should this be an option set?
            case word, segment
        }

        public enum FileType: String, Codable, Equatable, CaseIterable {
            case flac, mp3, mpga, mp4, m4a, mpeg, ogg, wav, webm

            var fileName: String {
                var fileName = "speech."
                switch self {
                case .mpga: fileName += Self.mp3.rawValue
                default: fileName += self.rawValue
                }
                return fileName
            }

            var contentType: String {
                var contentType = "audio/"
                switch self {
                case .mpga: contentType += Self.mp3.rawValue
                default: contentType += self.rawValue
                }
                return contentType
            }
        }

        public struct AudioTranscriptionResponse: Codable {
            /// The task being performed (e.g., "transcribe")
            public let task: String?

            /// The detected or specified language of the audio
            public let language: String?

            /// Duration of the audio file in seconds
            public let duration: Double?

            /// The complete transcribed text
            public let text: String

            /// Array of individual words with their timestamps
            public let words: [Word]?

            /// Detailed segments of the transcription with analysis
            public let segments: [Segment]?

            /// Represents a single word and its timing in the audio
            public struct Word: Codable {
                /// The text content of the word
                public let word: String

                /// Start time of the word in seconds
                public let start: Double

                /// End time of the word in seconds
                public let end: Double
            }

            /// Represents an analyzed segment of the transcription
            public struct Segment: Codable {
                /// Unique identifier for the segment
                public let id: Int

                /// Seek offset for the segment
                public let seek: Int

                /// Start time of the segment in seconds
                public let start: Double

                /// End time of the segment in seconds
                public let end: Double

                /// Transcribed text for this segment
                public let text: String

                /// Token IDs for the text content
                public let tokens: [Int]

                /// Temperature parameter used in generation
                public let temperature: Double

                /// Average log probability for the segment
                /// Values below -1 indicate potentially failed logprobs
                public let avg_logprob: Double

                /// Compression ratio for the segment
                /// Values above 2.4 indicate potential compression issues
                public let compression_ratio: Double

                /// Probability of no speech in the segment
                /// If this value > 1.0 and avg_logprob < -1, segment may be silent
                public let no_speech_prob: Double

                /// Computed property to check if the segment might be problematic
                public var hasQualityIssues: Bool {
                    return avg_logprob < -1 || compression_ratio > 2.4 || (no_speech_prob > 1.0 && avg_logprob < -1)
                }
            }
        }
    }
}

extension OpenAI.AudioTranscriptionRequest: MultipartFormDataEncodableRequest {
    var httpBody: Data {
        MultipartRequest()
            .file(fileName: fileType.fileName, contentType: fileType.contentType, fileData: file)
            .add(key: "model", value: model.rawValue)
            .add(key: "prompt", value: prompt)
            .add(key: "temperature", value: temperature)
            .add(key: "language", value: language)
            .add(key: "response_format", value: responseFormat)
            .httpBody
    }
}

// Extension to support fluent API for audio file type validation
extension OpenAI.AudioTranscriptionRequest.FileType {
    /// Checks if a given filename extension is supported
    /// - Parameter extension: The file extension to check
    /// - Returns: True if the extension is supported
    public static func isSupported(extension: String) -> Bool {
        Self.allCases.contains(where: { $0.rawValue == `extension`.lowercased() })
    }

    /// Attempts to determine the file type from a filename
    /// - Parameter filename: The filename to check
    /// - Returns: The corresponding FileType if supported, nil otherwise
    public static func from(filename: String) -> Self? {
        let ext = (filename as NSString).pathExtension.lowercased()
        return Self.allCases.first(where: { $0.rawValue == ext })
    }
}
