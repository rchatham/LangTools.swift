//
//  AppleIntelligence+FoundationModels.swift
//  LangTools
//
//  Bridges AppleIntelligence requests onto FoundationModels.LanguageModelSession.
//

#if canImport(FoundationModels) && !os(watchOS) && !os(tvOS)
import Foundation
import FoundationModels
import LangTools

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
enum FoundationModelsEngine {
    static func systemModel(for model: AppleIntelligenceModel) -> SystemLanguageModel {
        switch model {
        case .onDevice: return .default
        case .contentTagging: return SystemLanguageModel(useCase: .contentTagging)
        }
    }

    static func availability(for model: AppleIntelligenceModel) -> AppleIntelligence.Availability {
        switch systemModel(for: model).availability {
        case .available: return .available
        case .unavailable(.deviceNotEligible): return .unavailable(.deviceNotEligible)
        case .unavailable(.appleIntelligenceNotEnabled): return .unavailable(.appleIntelligenceNotEnabled)
        case .unavailable(.modelNotReady): return .unavailable(.modelNotReady)
        case .unavailable: return .unavailable(.unknown)
        }
    }

    static func respond(to request: AppleIntelligence.ChatRequest) async throws -> AppleIntelligence.ChatResponse {
        let (session, prompt) = try makeSession(for: request)
        let response = try await session.respond(to: prompt, options: options(for: request))
        return AppleIntelligence.ChatResponse(message: .init(role: .assistant, string: response.content))
    }

    static func streamResponse(to request: AppleIntelligence.ChatRequest) -> AsyncThrowingStream<AppleIntelligence.ChatResponse, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (session, prompt) = try makeSession(for: request)
                    // Snapshots carry the cumulative text; LangTools streams deltas.
                    var emitted = ""
                    for try await snapshot in session.streamResponse(to: prompt, options: options(for: request)) {
                        try Task.checkCancellation()
                        let text = snapshot.content
                        let delta = text.hasPrefix(emitted) ? String(text.dropFirst(emitted.count)) : text
                        emitted = text
                        guard !delta.isEmpty else { continue }
                        if case .terminated = continuation.yield(.init(delta: .init(content: delta))) { return }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    static func makeSession(for request: AppleIntelligence.ChatRequest) throws -> (LanguageModelSession, String) {
        let availability = availability(for: request.model)
        guard availability == .available else {
            if case .unavailable(let reason) = availability { throw AppleIntelligenceError.unavailable(reason) }
            throw AppleIntelligenceError.unavailable(.unknown)
        }
        let plan = try AppleIntelligence.transcriptPlan(for: request.messages)
        let session = LanguageModelSession(model: systemModel(for: request.model), transcript: transcript(for: plan))
        return (session, plan.prompt)
    }

    static func transcript(for plan: AppleIntelligence.TranscriptPlan) -> Transcript {
        var entries: [Transcript.Entry] = []
        if let instructions = plan.instructions {
            entries.append(.instructions(.init(segments: [.text(.init(content: instructions))], toolDefinitions: [])))
        }
        for turn in plan.history {
            switch turn {
            case .user(let text):
                entries.append(.prompt(.init(segments: [.text(.init(content: text))])))
            case .assistant(let text):
                entries.append(.response(.init(assetIDs: [], segments: [.text(.init(content: text))])))
            }
        }
        return Transcript(entries: entries)
    }

    static func options(for request: AppleIntelligence.ChatRequest) -> GenerationOptions {
        let sampling: GenerationOptions.SamplingMode? = switch request.sampling {
        case .greedy: .greedy
        case .topK(let k, let seed): .random(top: k, seed: seed)
        case .topP(let p, let seed): .random(probabilityThreshold: p, seed: seed)
        case nil: nil
        }
        return GenerationOptions(sampling: sampling, temperature: request.temperature, maximumResponseTokens: request.maximumResponseTokens)
    }
}
#endif
