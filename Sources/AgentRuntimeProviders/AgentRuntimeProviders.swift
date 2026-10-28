//
//  AgentRuntimeProviders.swift
//  AgentRuntimeProviders
//
//  Registers the chat providers that ship with LangTools, so a spec can name any of
//  them. Kept apart from `AgentRuntime` so a custom runtime can link only the
//  providers it uses.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools
import AgentRuntime
import OpenAI
import Anthropic
import OpenAICompatible
import Gemini
import XAI
import Ollama
import OpenRouter
import VercelAIGateway
import Perplexity
import Cohere

extension AgentProviderRegistry {
    public static var builtIn: AgentProviderRegistry {
        AgentProviderRegistry([
            ProviderRegistration(
                id: LangToolsProviderID(rawValue: "openai"), displayName: "OpenAI", apiKeyEnvironmentVariable: "OPENAI_API_KEY",
                makeClient: { config in
                    OpenAI(baseURL: config.baseURL ?? URL(string: "https://api.openai.com/v1/")!, apiKey: try config.requireAPIKey(for: LangToolsProviderID(rawValue: "openai")), session: config.session)
                },
                // OpenAI serves models newer than this library's catalog, so any ID is passed through.
                makeModel: { OpenAI.Model(rawValue: $0) ?? OpenAI.Model(customModelID: $0) }
            ),
            ProviderRegistration(
                id: LangToolsProviderID(rawValue: "anthropic"), displayName: "Anthropic", apiKeyEnvironmentVariable: "ANTHROPIC_API_KEY",
                makeClient: { config in
                    Anthropic(baseURL: config.baseURL ?? URL(string: "https://api.anthropic.com/v1/")!, apiKey: try config.requireAPIKey(for: LangToolsProviderID(rawValue: "anthropic")), session: config.session)
                },
                makeModel: { Anthropic.Model(rawValue: $0) }
            ),
            ProviderRegistration(
                id: Gemini.providerID, displayName: Gemini.displayName, apiKeyEnvironmentVariable: Gemini.apiKeyEnvironmentVariable,
                makeClient: { config in
                    Gemini(baseURL: config.baseURL ?? Gemini.defaultBaseURL, apiKey: try config.requireAPIKey(for: Gemini.providerID), session: config.session)
                },
                makeModel: { Gemini.Model(rawValue: $0) }
            ),
            ProviderRegistration(
                id: XAI.providerID, displayName: XAI.displayName, apiKeyEnvironmentVariable: XAI.apiKeyEnvironmentVariable,
                // XAI does not take a URLSession.
                makeClient: { config in XAI(baseURL: config.baseURL ?? XAI.defaultBaseURL, apiKey: try config.requireAPIKey(for: XAI.providerID)) },
                makeModel: { XAI.Model(rawValue: $0) }
            ),
            ProviderRegistration(
                id: LangToolsProviderID(rawValue: "ollama"), displayName: "Ollama", apiKeyEnvironmentVariable: "OLLAMA_API_KEY", requiresAPIKey: false,
                makeClient: { config in
                    let baseURL = config.baseURL ?? URL(string: "http://localhost:11434")!
                    guard let apiKey = config.apiKey else { return Ollama(baseURL: baseURL, session: config.session) }
                    return Ollama(baseURL: baseURL, apiKey: apiKey, session: config.session)
                },
                makeModel: { Ollama.Model(rawValue: $0) }
            ),
            compatible(OpenRouter.self) { OpenRouter(baseURL: $0, apiKey: $1, session: $2) },
            compatible(Groq.self) { Groq(baseURL: $0, apiKey: $1, session: $2) },
            compatible(Mistral.self) { Mistral(baseURL: $0, apiKey: $1, session: $2) },
            compatible(DeepSeek.self) { DeepSeek(baseURL: $0, apiKey: $1, session: $2) },
            compatible(Cerebras.self) { Cerebras(baseURL: $0, apiKey: $1, session: $2) },
            compatible(TogetherAI.self) { TogetherAI(baseURL: $0, apiKey: $1, session: $2) },
            compatible(Fireworks.self) { Fireworks(baseURL: $0, apiKey: $1, session: $2) },
            compatible(VercelAIGateway.self) { VercelAIGateway(baseURL: $0, apiKey: $1, session: $2) },
            compatible(Perplexity.self) { Perplexity(baseURL: $0, apiKey: $1, session: $2) },
            compatible(Cohere.self) { Cohere(baseURL: $0, apiKey: $1, session: $2) },
        ])
    }

    private static func compatible<Provider: OpenAICompatibleProvider>(
        _ type: Provider.Type,
        make: @escaping (URL, String, URLSession) -> Provider
    ) -> ProviderRegistration where Provider.Model == OpenAICompatibleModel<Provider> {
        ProviderRegistration(
            id: Provider.providerID, displayName: Provider.displayName, apiKeyEnvironmentVariable: Provider.apiKeyEnvironmentVariable,
            makeClient: { config in make(config.baseURL ?? Provider.defaultBaseURL, try config.requireAPIKey(for: Provider.providerID), config.session) },
            makeModel: { OpenAICompatibleModel<Provider>(rawValue: $0) }
        )
    }
}
