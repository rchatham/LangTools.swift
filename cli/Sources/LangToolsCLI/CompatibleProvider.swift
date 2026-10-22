//
//  CompatibleProvider.swift
//  LangToolsCLI
//
//  OpenAI-compatible providers, addressed as `<provider>/<model-id>`
//  (e.g. `groq/llama-3.3-70b-versatile`, `vercel/anthropic/claude-sonnet-4.5`).
//

import Foundation
import LangTools
import OpenAI
import OpenAICompatible
import VercelAIGateway
import Groq
import Mistral
import DeepSeek
import Cerebras
import TogetherAI
import Fireworks
import Cohere

enum CompatibleProvider: String, CaseIterable, Codable {
    // Raw values double as the model prefix and the matching `APIService` case.
    case vercel, groq, mistral, deepseek, cerebras, together, fireworks, cohere

    var type: any OpenAICompatibleProvider.Type { operations.type }

    /// The provider's generic operations, bound to its concrete type.
    private var operations: Operations {
        switch self {
        case .vercel: return Operations(VercelAIGateway.self) { VercelAIGateway(apiKey: $0) }
        case .groq: return Operations(Groq.self) { Groq(apiKey: $0) }
        case .mistral: return Operations(Mistral.self) { Mistral(apiKey: $0) }
        case .deepseek: return Operations(DeepSeek.self) { DeepSeek(apiKey: $0) }
        case .cerebras: return Operations(Cerebras.self) { Cerebras(apiKey: $0) }
        case .together: return Operations(TogetherAI.self) { TogetherAI(apiKey: $0) }
        case .fireworks: return Operations(Fireworks.self) { Fireworks(apiKey: $0) }
        case .cohere: return Operations(Cohere.self) { Cohere(apiKey: $0) }
        }
    }

    var prefix: String { rawValue + "/" }
    var displayName: String { type.displayName }
    var environmentVariable: String { type.apiKeyEnvironmentVariable }
    var providerID: LangToolsProviderID { type.providerID }
    var supportsModelListing: Bool { type.supportsModelListing }
    var knownModelIDs: [String] { operations.knownModelIDs }
    var apiService: APIService { APIService(rawValue: rawValue)! }

    /// The UI category with the same display name.
    var category: Provider { Provider(rawValue: displayName)! }

    init?(category: Provider) {
        guard let provider = Self.allCases.first(where: { $0.displayName == category.rawValue }) else { return nil }
        self = provider
    }

    init?(apiService: APIService) {
        self.init(rawValue: apiService.rawValue)
    }

    /// Returns nil for an empty or whitespace-padded ID.
    static func validModelID(_ id: String) -> String? {
        guard !id.isEmpty, id == id.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return id
    }

    func makeClient(apiKey: String) -> any LangTools {
        operations.makeClient(apiKey)
    }

    /// The tagged model used on the wire, so the toolchain routes it here.
    func openAIModel(id: String) -> OpenAIModel {
        OpenAIModel(customModelID: id, providerID: providerID)
    }

    /// The registered client and typed model, for agents that build their own requests.
    func providerContext(id: String, toolchain: LangToolchain) -> (langTool: any LangTools, model: any RawRepresentable)? {
        operations.context(id, toolchain)
    }

    func isRegistered(in toolchain: LangToolchain) -> Bool {
        operations.isRegistered(toolchain)
    }

    /// The provider's chat models: its catalog when it has one, else its
    /// suggested models. Nil when the provider is not registered.
    func chatModelCatalog(toolchain: LangToolchain) async -> [OpenAICompatibleModelInfo]? {
        guard isRegistered(in: toolchain) else { return nil }
        let known = knownModelIDs.map { OpenAICompatibleModelInfo(id: $0) }
        guard supportsModelListing else { return known }
        do {
            let models = try await operations.listModels(toolchain).filter(\.isChatModel)
            return models.isEmpty ? known : models
        } catch {
            // The provider may be unreachable; offer its suggested models.
            return known
        }
    }

    private struct Operations {
        let type: any OpenAICompatibleProvider.Type
        let knownModelIDs: [String]
        let makeClient: (String) -> any LangTools
        let isRegistered: (LangToolchain) -> Bool
        let context: (String, LangToolchain) -> (langTool: any LangTools, model: any RawRepresentable)?
        let listModels: (LangToolchain) async throws -> [OpenAICompatibleModelInfo]

        init<P: OpenAICompatibleProvider>(_ type: P.Type, makeClient: @escaping (String) -> P) {
            self.type = type
            knownModelIDs = type.knownModels.map(\.rawValue)
            self.makeClient = makeClient
            isRegistered = { $0.langTool(type) != nil }
            context = { id, toolchain in
                guard let client = toolchain.langTool(type), let model = OpenAICompatibleModel<P>(rawValue: id) else { return nil }
                return (client, model)
            }
            listModels = { toolchain in
                guard let client = toolchain.langTool(type) else { return [] }
                return try await client.listModels()
            }
        }
    }
}
