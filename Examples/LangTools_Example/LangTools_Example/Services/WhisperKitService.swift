//
//  WhisperKitService.swift
//  LangTools_Example
//
//  Created by Reid Chatham on 12/21/24.
//

import Foundation
import LangTools
import WhisperKit
import AVFoundation

struct WhisperKitService: LangTools {
    enum Model: String, Codable {
        case largeV3 = "large-v3"
    }

    typealias ErrorResponse = WhisperKitErrorResponse

    func perform<Request>(request: Request) async throws -> Request.Response where Request : LangToolsRequest {
        let pipe = try await WhisperKit()
        guard let audioRequest = request as? AudioTranscriptionRequest else { throw WhisperKitErrorResponse.whisperKitFailed }

        // First, create a temporary file URL
        let tempDirectory = FileManager.default.temporaryDirectory
        let tempFileURL = tempDirectory.appendingPathComponent(UUID().uuidString + ".wav")

        // Write the Data to the temporary file
        try audioRequest.file.write(to: tempFileURL)

//        let avAudioFile = try AVAudioFile(forReading: tempFileURL)
        let transcription = try await pipe.transcribe(audioPath: tempFileURL.path())
        return AudioTranscriptionResponse(text: transcription.reduce("", { $0.normalized.appending($1.text) })) as! Request.Response
    }

    func stream<Request>(request: Request) -> AsyncThrowingStream<Request.Response, any Error> where Request : LangToolsStreamableRequest {
        fatalError()
    }

    var requestTypes: [(any LangToolsRequest) -> Bool] {
        return [
            { ($0 as? AudioTranscriptionRequest) != nil }
        ]
    }
}

extension WhisperKitService {
    public struct AudioTranscriptionRequest: LangToolsRequest {
        public typealias Response = AudioTranscriptionResponse
        public typealias LangTool = WhisperKitService
        public static var path: String { "audio/transcriptions" }

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
        public let model: Model
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

        public init(file: Data, fileType: FileType, model: Model, prompt: String? = nil, temperature: Double? = nil, language: String? = nil, responseFormat: ResponseFormat? = nil) {
            self.file = file
            self.fileType = fileType
            self.model = model
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

            var fileName: String { get {
                var fileName = "speech."
                switch self {
                case .mpga:
                    fileName += Self.mp3.rawValue
                default:
                    fileName += self.rawValue
                }

                return fileName
            }}

            var contentType: String { get {
                var contentType = "audio/"
                switch self {
                case .mpga:
                    contentType += Self.mp3.rawValue
                default:
                    contentType += self.rawValue
                }

                return contentType
            }}
        }
    }

    public struct AudioTranscriptionResponse: Codable, Equatable {
        /// The transcribed text.
        public let text: String
    }
}

enum WhisperKitErrorResponse: Error, Codable {
    case whisperKitFailed
}
