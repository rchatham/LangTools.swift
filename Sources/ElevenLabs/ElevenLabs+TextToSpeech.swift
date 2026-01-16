//
//  ElevenLabs+TextToSpeech.swift
//  ElevenLabs
//
//  Created by Reid Chatham on 1/16/26.
//

import Foundation
import LangTools

// MARK: - Text to Speech Request

extension ElevenLabs {
    /// Standard text-to-speech request (non-streaming)
    public struct TextToSpeechRequest: Codable, LangToolsRequest, LangToolsTTSRequest {
        public typealias LangTool = ElevenLabs
        public static var endpoint: String { "text-to-speech" }

        public let text: String
        public let modelId: String
        public let voiceSettings: VoiceSettings?
        public let pronunciationDictionaryLocators: [PronunciationDictionaryLocator]?
        public let seed: Int?
        public let previousText: String?
        public let nextText: String?
        public let previousRequestIds: [String]?
        public let nextRequestIds: [String]?

        private let voiceId: String

        public var endpoint: String { "text-to-speech/\(voiceId)" }

        public init(
            text: String,
            voiceId: String,
            modelId: String = ElevenLabsModel.elevenMultilingualV2.id,
            voiceSettings: VoiceSettings? = nil,
            pronunciationDictionaryLocators: [PronunciationDictionaryLocator]? = nil,
            seed: Int? = nil,
            previousText: String? = nil,
            nextText: String? = nil,
            previousRequestIds: [String]? = nil,
            nextRequestIds: [String]? = nil
        ) {
            self.text = text
            self.voiceId = voiceId
            self.modelId = modelId
            self.voiceSettings = voiceSettings
            self.pronunciationDictionaryLocators = pronunciationDictionaryLocators
            self.seed = seed
            self.previousText = previousText
            self.nextText = nextText
            self.previousRequestIds = previousRequestIds
            self.nextRequestIds = nextRequestIds
        }

        public struct PronunciationDictionaryLocator: Codable, Sendable {
            public let pronunciationDictionaryId: String
            public let versionId: String

            public init(pronunciationDictionaryId: String, versionId: String) {
                self.pronunciationDictionaryId = pronunciationDictionaryId
                self.versionId = versionId
            }

            enum CodingKeys: String, CodingKey {
                case pronunciationDictionaryId = "pronunciation_dictionary_id"
                case versionId = "version_id"
            }
        }

        enum CodingKeys: String, CodingKey {
            case text, seed
            case modelId = "model_id"
            case voiceSettings = "voice_settings"
            case pronunciationDictionaryLocators = "pronunciation_dictionary_locators"
            case previousText = "previous_text"
            case nextText = "next_text"
            case previousRequestIds = "previous_request_ids"
            case nextRequestIds = "next_request_ids"
        }
    }

    /// Streaming text-to-speech request
    public struct TextToSpeechStreamRequest: Codable, LangToolsRequest {
        public typealias Response = Data
        public typealias LangTool = ElevenLabs
        public static var endpoint: String { "text-to-speech" }

        public let text: String
        public let modelId: String
        public let voiceSettings: VoiceSettings?
        public let outputFormat: ElevenLabsOutputFormat?

        private let voiceId: String

        public var endpoint: String { "text-to-speech/\(voiceId)/stream" }

        public init(
            text: String,
            voiceId: String,
            modelId: String = ElevenLabsModel.elevenFlashV2_5.id,
            voiceSettings: VoiceSettings? = nil,
            outputFormat: ElevenLabsOutputFormat? = nil
        ) {
            self.text = text
            self.voiceId = voiceId
            self.modelId = modelId
            self.voiceSettings = voiceSettings
            self.outputFormat = outputFormat
        }

        enum CodingKeys: String, CodingKey {
            case text
            case modelId = "model_id"
            case voiceSettings = "voice_settings"
            case outputFormat = "output_format"
        }
    }
}

// MARK: - Voices List Request

extension ElevenLabs {
    /// Request to list available voices
    public struct VoicesListRequest: Codable, LangToolsRequest {
        public typealias Response = VoicesListResponse
        public typealias LangTool = ElevenLabs
        public static var endpoint: String { "voices" }
        public static var httpMethod: HTTPMethod { .get }

        public init() {}
    }

    public struct VoicesListResponse: Codable {
        public let voices: [Voice]

        public struct Voice: Codable, Identifiable, Sendable {
            public let voiceId: String
            public let name: String
            public let samples: [Sample]?
            public let category: String?
            public let fineTuning: FineTuning?
            public let labels: [String: String]?
            public let description: String?
            public let previewUrl: String?
            public let availableForTiers: [String]?
            public let settings: VoiceSettings?
            public let sharingStatus: String?
            public let highQualityBaseModelIds: [String]?

            public var id: String { voiceId }

            public struct Sample: Codable, Sendable {
                public let sampleId: String
                public let fileName: String
                public let mimeType: String
                public let sizeBytes: Int
                public let hash: String

                enum CodingKeys: String, CodingKey {
                    case sampleId = "sample_id"
                    case fileName = "file_name"
                    case mimeType = "mime_type"
                    case sizeBytes = "size_bytes"
                    case hash
                }
            }

            public struct FineTuning: Codable, Sendable {
                public let isAllowedToFineTune: Bool?
                public let state: [String: String]?
                public let verificationFailures: [String]?
                public let verificationAttemptsCount: Int?
                public let manualVerificationRequested: Bool?
                public let language: String?
                public let progress: [String: Double]?
                public let message: [String: String]?
                public let datasetDurationSeconds: Double?
                public let verificationAttempts: [VerificationAttempt]?
                public let sliceIds: [String]?
                public let manualVerification: ManualVerification?

                public struct VerificationAttempt: Codable, Sendable {
                    public let text: String
                    public let dateUnix: Int
                    public let accepted: Bool
                    public let similarity: Double
                    public let levenshteinDistance: Double
                    public let recording: Recording?

                    public struct Recording: Codable, Sendable {
                        public let recordingId: String
                        public let mimeType: String
                        public let sizeBytes: Int
                        public let uploadDateUnix: Int
                        public let transcription: String

                        enum CodingKeys: String, CodingKey {
                            case recordingId = "recording_id"
                            case mimeType = "mime_type"
                            case sizeBytes = "size_bytes"
                            case uploadDateUnix = "upload_date_unix"
                            case transcription
                        }
                    }

                    enum CodingKeys: String, CodingKey {
                        case text, accepted, similarity, recording
                        case dateUnix = "date_unix"
                        case levenshteinDistance = "levenshtein_distance"
                    }
                }

                public struct ManualVerification: Codable, Sendable {
                    public let extraText: String?
                    public let requestTimeUnix: Int?
                    public let files: [File]?

                    public struct File: Codable, Sendable {
                        public let fileId: String
                        public let fileName: String
                        public let mimeType: String
                        public let sizeBytes: Int
                        public let uploadDateUnix: Int

                        enum CodingKeys: String, CodingKey {
                            case fileId = "file_id"
                            case fileName = "file_name"
                            case mimeType = "mime_type"
                            case sizeBytes = "size_bytes"
                            case uploadDateUnix = "upload_date_unix"
                        }
                    }

                    enum CodingKeys: String, CodingKey {
                        case extraText = "extra_text"
                        case requestTimeUnix = "request_time_unix"
                        case files
                    }
                }

                enum CodingKeys: String, CodingKey {
                    case state, language, progress, message
                    case isAllowedToFineTune = "is_allowed_to_fine_tune"
                    case verificationFailures = "verification_failures"
                    case verificationAttemptsCount = "verification_attempts_count"
                    case manualVerificationRequested = "manual_verification_requested"
                    case datasetDurationSeconds = "dataset_duration_seconds"
                    case verificationAttempts = "verification_attempts"
                    case sliceIds = "slice_ids"
                    case manualVerification = "manual_verification"
                }
            }

            enum CodingKeys: String, CodingKey {
                case name, samples, category, labels, description, settings
                case voiceId = "voice_id"
                case fineTuning = "fine_tuning"
                case previewUrl = "preview_url"
                case availableForTiers = "available_for_tiers"
                case sharingStatus = "sharing_status"
                case highQualityBaseModelIds = "high_quality_base_model_ids"
            }
        }
    }
}

// MARK: - Models List Request

extension ElevenLabs {
    /// Request to list available models
    public struct ModelsListRequest: Codable, LangToolsRequest {
        public typealias Response = [ModelInfo]
        public typealias LangTool = ElevenLabs
        public static var endpoint: String { "models" }
        public static var httpMethod: HTTPMethod { .get }

        public init() {}
    }

    public struct ModelInfo: Codable, Identifiable, Sendable {
        public let modelId: String
        public let name: String
        public let canBeFinetuned: Bool
        public let canDoTextToSpeech: Bool
        public let canDoVoiceConversion: Bool
        public let canUseStyle: Bool
        public let canUseSpeakerBoost: Bool
        public let servesProVoices: Bool
        public let tokenCostFactor: Double
        public let description: String
        public let requiresAlphaAccess: Bool
        public let maxCharactersRequestFreeUser: Int
        public let maxCharactersRequestSubscribedUser: Int
        public let maximumTextLengthPerRequest: Int
        public let languages: [Language]
        public let modelRates: ModelRates?
        public let concurrencyGroup: String?

        public var id: String { modelId }

        public struct Language: Codable, Sendable {
            public let languageId: String
            public let name: String

            enum CodingKeys: String, CodingKey {
                case languageId = "language_id"
                case name
            }
        }

        public struct ModelRates: Codable, Sendable {
            public let characterCostMultiplier: Double

            enum CodingKeys: String, CodingKey {
                case characterCostMultiplier = "character_cost_multiplier"
            }
        }

        enum CodingKeys: String, CodingKey {
            case name, description, languages
            case modelId = "model_id"
            case canBeFinetuned = "can_be_finetuned"
            case canDoTextToSpeech = "can_do_text_to_speech"
            case canDoVoiceConversion = "can_do_voice_conversion"
            case canUseStyle = "can_use_style"
            case canUseSpeakerBoost = "can_use_speaker_boost"
            case servesProVoices = "serves_pro_voices"
            case tokenCostFactor = "token_cost_factor"
            case requiresAlphaAccess = "requires_alpha_access"
            case maxCharactersRequestFreeUser = "max_characters_request_free_user"
            case maxCharactersRequestSubscribedUser = "max_characters_request_subscribed_user"
            case maximumTextLengthPerRequest = "maximum_text_length_per_request"
            case modelRates = "model_rates"
            case concurrencyGroup = "concurrency_group"
        }
    }
}
