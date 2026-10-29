//
//  CompatibleModelCatalog.swift
//  LangToolsApp
//
//  Caches each OpenAI-compatible provider's chat models so the picker and
//  access checks work at launch and offline. A provider is refreshed when its
//  key is saved and when the app starts with its key configured. Until then,
//  and for providers without a catalog endpoint, its suggested models are used.
//

import Foundation
import OpenAI
import OpenAICompatible

public final class CompatibleModelCatalog: @unchecked Sendable {
    public static let shared = CompatibleModelCatalog()
    static func storageKey(for provider: CompatibleProvider) -> String { "compatibleModelCatalog.\(provider.rawValue)" }

    /// The cached subset of a catalog entry that the app uses.
    public struct Entry: Codable, Equatable, Sendable {
        public let id: String
        public let name: String?
        public let contextLength: Int?
        /// Nil when the catalog does not report tool support.
        public let supportsTools: Bool?

        public init(id: String, name: String? = nil, contextLength: Int? = nil, supportsTools: Bool? = nil) {
            self.id = id
            self.name = name
            self.contextLength = contextLength
            self.supportsTools = supportsTools
        }

        init(_ info: OpenAICompatibleModelInfo) {
            self.init(id: info.id, name: info.name, contextLength: info.contextWindow, supportsTools: info.supportsTools)
        }
    }

    public typealias Fetcher = @Sendable (_ provider: CompatibleProvider, _ apiKey: String) async throws -> [OpenAICompatibleModelInfo]

    public static let liveFetcher: Fetcher = { provider, apiKey in
        try await provider.listModels(apiKey: apiKey)
    }

    private let userDefaults: UserDefaults
    private let fetcher: Fetcher
    private let lock = NSLock()
    private var decoded: [CompatibleProvider: [Entry]] = [:]

    public init(userDefaults: UserDefaults = .standard, fetcher: @escaping Fetcher = CompatibleModelCatalog.liveFetcher) {
        self.userDefaults = userDefaults
        self.fetcher = fetcher
    }

    /// Cached catalog entries, sorted by ID; empty before the first fetch.
    public func entries(for provider: CompatibleProvider) -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        if let entries = decoded[provider] { return entries }
        let entries = userDefaults.data(forKey: Self.storageKey(for: provider))
            .flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        decoded[provider] = entries
        return entries
    }

    public func entry(for provider: CompatibleProvider, id: String) -> Entry? {
        entries(for: provider).first { $0.id == id }
    }

    /// The cached catalog, or the provider's suggested models when there is none.
    public func modelIDs(for provider: CompatibleProvider) -> [String] {
        let cached = entries(for: provider).map(\.id)
        return cached.isEmpty ? provider.knownModelIDs : cached
    }

    /// Stores chat-model entries whose ID is usable, sorted by ID.
    public func store(_ entries: [Entry], for provider: CompatibleProvider) {
        let sorted = entries.filter { CompatibleProvider.validModelID($0.id) != nil }.sorted { $0.id < $1.id }
        lock.lock()
        defer { lock.unlock() }
        decoded[provider] = sorted
        if let data = try? JSONEncoder().encode(sorted) {
            userDefaults.set(data, forKey: Self.storageKey(for: provider))
        }
    }

    /// Fetches the provider's chat models with `apiKey` and caches them. A
    /// provider without a catalog endpoint keeps its suggested models. On
    /// failure the previous cache is kept.
    @discardableResult
    public func refresh(_ provider: CompatibleProvider, apiKey: String) async throws -> [Entry] {
        guard provider.supportsModelListing else { return entries(for: provider) }
        let entries = try await fetcher(provider, apiKey).filter(\.isChatModel).map(Entry.init)
        store(entries, for: provider)
        return self.entries(for: provider)
    }

    /// Refreshes, in the background, each provider (or only `provider`) with
    /// a stored key, then republishes provider access so the picker updates.
    public func refreshInBackground(_ provider: CompatibleProvider? = nil, keychainService: KeychainService = .shared, accessManager: ProviderAccessManager = .shared) {
        let providers = provider.map { [$0] } ?? CompatibleProvider.allCases
        for provider in providers where provider.supportsModelListing {
            guard let apiKey = keychainService.getApiKey(for: provider.service), !apiKey.isEmpty else { continue }
            Task {
                do {
                    try await refresh(provider, apiKey: apiKey)
                    accessManager.refresh()
                } catch {
                    // Keep the cached catalog; suggested models remain available.
                    NSLog("%@ catalog refresh failed; keeping the cached catalog: %@", provider.displayName, error.localizedDescription)
                }
            }
        }
    }
}
