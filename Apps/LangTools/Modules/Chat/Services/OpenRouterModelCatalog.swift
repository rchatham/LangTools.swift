//
//  OpenRouterModelCatalog.swift
//  LangToolsApp
//
//  Caches OpenRouter's model catalog so the picker and access checks work at
//  launch and offline. The catalog is refreshed when a key is saved and when
//  the app starts with a key configured.
//

import Foundation
import OpenRouter

public final class OpenRouterModelCatalog: @unchecked Sendable {
    public static let shared = OpenRouterModelCatalog()
    static let storageKey = "openRouterModelCatalog"

    /// The cached subset of a catalog entry that the app uses.
    public struct Entry: Codable, Equatable, Sendable {
        public let id: String
        public let name: String?
        public let contextLength: Int?
        public let supportsTools: Bool

        public init(id: String, name: String? = nil, contextLength: Int? = nil, supportsTools: Bool) {
            self.id = id
            self.name = name
            self.contextLength = contextLength
            self.supportsTools = supportsTools
        }

        init(_ info: OpenRouter.ModelInfo) {
            self.init(id: info.id, name: info.name, contextLength: info.contextLength ?? info.topProvider?.contextLength, supportsTools: info.supportsTools)
        }

        public var model: OpenRouter.Model { OpenRouter.Model(stringLiteral: id) }
    }

    public typealias Fetcher = @Sendable (_ apiKey: String) async throws -> [OpenRouter.ModelInfo]

    public static let liveFetcher: Fetcher = { apiKey in
        try await OpenRouter(apiKey: apiKey, appTitle: "LangTools").listModels()
    }

    private let userDefaults: UserDefaults
    private let fetcher: Fetcher
    private let lock = NSLock()
    private var decoded: [Entry]?

    public init(userDefaults: UserDefaults = .standard, fetcher: @escaping Fetcher = OpenRouterModelCatalog.liveFetcher) {
        self.userDefaults = userDefaults
        self.fetcher = fetcher
    }

    /// Cached entries, sorted by slug so the picker groups models by vendor.
    public func entries() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        if let decoded { return decoded }
        let entries = userDefaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        decoded = entries
        return entries
    }

    public func entry(for model: OpenRouter.Model) -> Entry? {
        entries().first { $0.id == model.rawValue }
    }

    /// OpenRouter's `openrouter/auto` router first, then the cached catalog.
    /// The router is always offered so the provider works before the first fetch.
    public func models() -> [OpenRouter.Model] {
        [.auto] + entries().compactMap { OpenRouter.Model(rawValue: $0.id) }.filter { $0 != .auto }
    }

    /// Stores entries whose id is a valid slug, sorted by slug.
    public func store(_ entries: [Entry]) {
        let sorted = entries.filter { OpenRouter.Model(rawValue: $0.id) != nil }.sorted { $0.id < $1.id }
        lock.lock()
        defer { lock.unlock() }
        decoded = sorted
        if let data = try? JSONEncoder().encode(sorted) {
            userDefaults.set(data, forKey: Self.storageKey)
        }
    }

    /// Fetches the catalog with `apiKey` and caches it. On failure the previous
    /// cache is kept.
    @discardableResult
    public func refresh(apiKey: String) async throws -> [Entry] {
        let entries = try await fetcher(apiKey).map(Entry.init)
        store(entries)
        return self.entries()
    }

    /// Refreshes in the background when an OpenRouter key is stored, then
    /// republishes provider access so the picker shows the new models.
    public func refreshInBackground(keychainService: KeychainService = .shared, accessManager: ProviderAccessManager = .shared) {
        guard let apiKey = keychainService.getApiKey(for: .openRouter), !apiKey.isEmpty else { return }
        Task {
            do {
                try await refresh(apiKey: apiKey)
                accessManager.refresh()
            } catch {
                // Keep the cached catalog; models can still be used by slug.
                NSLog("OpenRouter catalog refresh failed; keeping the cached catalog: %@", error.localizedDescription)
            }
        }
    }
}
