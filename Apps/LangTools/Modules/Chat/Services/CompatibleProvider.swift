//
//  CompatibleProvider.swift
//  LangToolsApp
//
//  OpenAI-compatible providers. Each one's raw value is its model route
//  (`groq/<model-id>`), its `APIService`, and its `AccessDestination`.
//

import Foundation
import LangTools
import OpenAI
import OpenAICompatible
import VercelAIGateway
import Cohere
import Perplexity
import OpenRouter

public enum CompatibleProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case openrouter, vercel, groq, mistral, deepseek, cerebras, together, fireworks, cohere, perplexity

    public var id: String { rawValue }
    public var displayName: String { operations.type.displayName }
    public var providerID: LangToolsProviderID { operations.type.providerID }
    public var supportsModelListing: Bool { operations.type.supportsModelListing }
    /// True for a provider that serves only OpenAI's Responses format (Perplexity).
    public var usesResponses: Bool { operations.type.compatibleFormats == .responses }
    /// Suggested models, offered before (or instead of) a catalog fetch.
    public var knownModelIDs: [String] { operations.knownModelIDs }

    public var service: APIService { APIService(rawValue: rawValue)! }
    public var route: ModelRoute { ModelRoute(rawValue: rawValue)! }
    public var accessDestination: AccessDestination { AccessDestination(rawValue: rawValue)! }

    public init?(service: APIService) { self.init(rawValue: service.rawValue) }

    /// Returns nil for an empty or whitespace-padded model ID.
    public static func validModelID(_ id: String) -> String? {
        guard !id.isEmpty, id == id.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return id
    }

    public func makeClient(apiKey: String) -> any LangTools {
        operations.makeClient(apiKey)
    }

    /// The tagged model used on the wire, so the toolchain routes it here.
    public func openAIModel(id: String) -> OpenAIModel {
        OpenAIModel(customModelID: id, providerID: providerID)
    }

    /// The registered client and typed model, for agents.
    func providerContext(id: String, toolchain: LangToolchain) -> (langTool: any LangTools, model: any RawRepresentable)? {
        operations.context(id, toolchain)
    }

    /// Fetches the provider's catalog with `apiKey`.
    func listModels(apiKey: String) async throws -> [OpenAICompatibleModelInfo] {
        try await operations.listModels(apiKey)
    }

    private var operations: Operations {
        switch self {
        case .openrouter: return Operations(OpenRouter.self) { OpenRouter(apiKey: $0, appTitle: "LangTools") }
        case .vercel: return Operations(VercelAIGateway.self) { VercelAIGateway(apiKey: $0) }
        case .groq: return Operations(Groq.self) { Groq(apiKey: $0) }
        case .mistral: return Operations(Mistral.self) { Mistral(apiKey: $0) }
        case .deepseek: return Operations(DeepSeek.self) { DeepSeek(apiKey: $0) }
        case .cerebras: return Operations(Cerebras.self) { Cerebras(apiKey: $0) }
        case .together: return Operations(TogetherAI.self) { TogetherAI(apiKey: $0) }
        case .fireworks: return Operations(Fireworks.self) { Fireworks(apiKey: $0) }
        case .cohere: return Operations(Cohere.self) { Cohere(apiKey: $0) }
        case .perplexity: return Operations(Perplexity.self) { Perplexity(apiKey: $0) }
        }
    }

    /// The provider's generic operations, bound to its concrete type.
    private struct Operations {
        let type: any OpenAICompatibleProvider.Type
        let knownModelIDs: [String]
        let makeClient: (String) -> any LangTools
        let context: (String, LangToolchain) -> (langTool: any LangTools, model: any RawRepresentable)?
        let listModels: (String) async throws -> [OpenAICompatibleModelInfo]

        init<P: OpenAICompatibleProvider>(_ type: P.Type, makeClient: @escaping (String) -> P) {
            self.type = type
            knownModelIDs = type.knownModels.map(\.rawValue)
            self.makeClient = makeClient
            context = { id, toolchain in
                guard let client = toolchain.langTool(type), let model = OpenAICompatibleModel<P>(rawValue: id) else { return nil }
                return (client, model)
            }
            listModels = { apiKey in try await makeClient(apiKey).listModels() }
        }
    }
}
