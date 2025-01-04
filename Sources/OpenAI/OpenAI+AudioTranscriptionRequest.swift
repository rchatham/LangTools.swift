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
            case json
            case text
            case verboseJson = "verbose_json"
            case srt
            case vtt
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

        public init(file: Data, fileType: FileType, prompt: String? = nil, temperature: Double? = nil, language: String? = nil, responseFormat: ResponseFormat? = nil) {
            self.file = file
            self.fileType = fileType
            self.prompt = prompt
            self.temperature = temperature
            self.language = language
            self.responseFormat = responseFormat
        }

        public enum FileType: String, Codable, Equatable, CaseIterable {
            case flac
            case mp3, mpga
            case mp4, m4a
            case mpeg
            case ogg
            case wav
            case webm

            var fileName: String {
                var fileName = "speech."
                switch self {
                case .mpga:
                    fileName += Self.mp3.rawValue
                default:
                    fileName += self.rawValue
                }

                return fileName
            }

            var contentType: String {
                var contentType = "audio/"
                switch self {
                case .mpga:
                    contentType += Self.mp3.rawValue
                default:
                    contentType += self.rawValue
                }

                return contentType
            }
        }
    }

    public struct AudioTranscriptionResponse: Codable, Equatable {

        /// The transcribed text.
        public let text: String
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
