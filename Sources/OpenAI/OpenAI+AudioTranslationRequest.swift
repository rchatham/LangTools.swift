//
//  OpenAI+AudioTranslationRequest.swift
//  LangTools
//
//  Created by Reid Chatham on 1/8/25.
//  Adapted from AudioTranscriptionQuery.swift - Created by Sergii Kryvoblotskyi on 02/04/2023.
//

import Foundation
import LangTools

extension OpenAI {
    public struct AudioTranslationRequest: LangToolsRequest {
        public typealias Response = AudioTranslationResponse
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

        public init(file: Data, fileType: FileType, prompt: String? = nil, temperature: Double? = nil, responseFormat: ResponseFormat? = nil) {
            self.file = file
            self.fileType = fileType
            self.prompt = prompt
            self.temperature = temperature
            self.responseFormat = responseFormat
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
    }

    public struct AudioTranslationResponse: Codable, Equatable {

        /// The transcribed text.
        public let text: String
    }
}

extension OpenAI.AudioTranslationRequest: MultipartFormDataEncodableRequest {
    func multipartFormData() -> (body: Data, contentType: String) {
        let request = MultipartRequest()
            .file(fileName: fileType.fileName, contentType: fileType.contentType, fileData: file)
            .add(key: "model", value: model.rawValue)
            .add(key: "prompt", value: prompt)
            .add(key: "temperature", value: temperature)
            .add(key: "response_format", value: responseFormat)
        return (body: request.httpBody, contentType: request.httpContentTypeHeadeValue)
    }
}
