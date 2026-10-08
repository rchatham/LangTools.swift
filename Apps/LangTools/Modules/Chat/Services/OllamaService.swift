//
//  OllamaService.swift
//
//  Created by Reid Chatham on 2/25/25.
//

import Combine
import Foundation
import LangTools
import Ollama

public class OllamaService: ObservableObject {
    public static let shared = OllamaService()

    struct Dependencies {
        var availableModels: (Ollama) async throws -> [Ollama.Model]
        var runningModels: (Ollama) async throws -> [Ollama.ListRunningModelsResponse.RunningModelInfo]
        var checkConnection: (Ollama) async throws -> Void
        var cacheModels: ([Ollama.Model]) -> Void

        static let live = Dependencies(
            availableModels: { ollama in
                try await ollama.listModels().models.compactMap { Ollama.Model(rawValue: $0.name) }
            },
            runningModels: { ollama in
                try await ollama.listRunningModels().models
            },
            checkConnection: { ollama in
                _ = try await ollama.version()
            },
            cacheModels: Model.updateCachedOllamaModels
        )
    }

    @Published public var availableModels: [Ollama.Model] = []
    @Published var runningModels: [Ollama.ListRunningModelsResponse.RunningModelInfo] = []
    @Published var isLoading = false
    @Published public var error: Error?

    private let userDefaults: UserDefaults
    private let dependencies: Dependencies
    private var ollama: Ollama?
    private var endpointError: Error?
    private var endpointGeneration: UInt = 0
    private var refreshGeneration: UInt = 0
    private var refreshTask: Task<Void, Never>?

    @MainActor var configuredBaseURL: URL? { ollama?.configuration.baseURL }

    init(
        userDefaults: UserDefaults = .standard,
        dependencies: Dependencies = .live
    ) {
        self.userDefaults = userDefaults
        self.dependencies = dependencies
        do {
            ollama = try OllamaEndpointPolicy.makeOllama(userDefaults: userDefaults)
        } catch {
            endpointError = error
            self.error = error
        }
    }

    @MainActor
    private func configuredOllama() throws -> Ollama {
        if let endpointError {
            throw endpointError
        }
        guard let ollama else {
            throw OllamaEndpointError.malformed("Missing Ollama client")
        }
        return ollama
    }

    @MainActor
    @discardableResult
    public func refreshModels() -> Task<Void, Never> {
        refreshTask?.cancel()
        refreshGeneration &+= 1
        let operationGeneration = refreshGeneration
        let operationEndpointGeneration = endpointGeneration
        isLoading = true
        error = nil

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let ollama = try self.configuredOllama()
                let models = try await self.dependencies.availableModels(ollama)
                let runningModels = (try? await self.dependencies.runningModels(ollama)) ?? []

                await MainActor.run {
                    guard self.isCurrentRefresh(
                        operationGeneration,
                        endpointGeneration: operationEndpointGeneration
                    ) else { return }
                    self.availableModels = models
                    self.runningModels = runningModels
                    self.dependencies.cacheModels(models)
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    guard self.isCurrentRefresh(
                        operationGeneration,
                        endpointGeneration: operationEndpointGeneration
                    ) else { return }
                    self.error = error
                    self.isLoading = false
                }
            }
        }
        refreshTask = task
        return task
    }

    @MainActor
    private func isCurrentRefresh(_ refreshGeneration: UInt, endpointGeneration: UInt) -> Bool {
        self.refreshGeneration == refreshGeneration && self.endpointGeneration == endpointGeneration
    }

    @MainActor
    func pullModel(_ modelName: String, progressHandler: @escaping (Double) -> Void) async throws {
        let ollama = try configuredOllama()
        for try await response in ollama.streamPullModel(modelName) {
            if let total = response.total, let completed = response.completed {
                let progress = Double(completed) / Double(total)
                await MainActor.run {
                    progressHandler(progress)
                }
            }
        }

        _ = refreshModels()
    }

    @MainActor
    func loadModel(_ model: Ollama.Model) async throws {
        let ollama = try configuredOllama()
        _ = try await ollama.chat(
            model: model,
            messages: [Ollama.Message(role: .user, content: "Hello")]
        )

        _ = refreshModels()
    }

    @MainActor
    @discardableResult
    func updateBaseUrl(_ urlString: String) throws -> URL {
        let url = try OllamaEndpointPolicy.validate(urlString)
        let updatedOllama = try OllamaEndpointPolicy.makeOllama(baseURL: url)

        // This operation has no suspension point. When it returns, the persisted endpoint used
        // by chat dispatch and the in-memory endpoint used for discovery are guaranteed to match.
        userDefaults.set(url.absoluteString, forKey: OllamaEndpointPolicy.userDefaultsKey)
        if configuredBaseURL != url || endpointError != nil {
            endpointGeneration &+= 1
            refreshGeneration &+= 1
            refreshTask?.cancel()
            refreshTask = nil
            availableModels = []
            runningModels = []
            dependencies.cacheModels([])
            isLoading = false
        }
        ollama = updatedOllama
        endpointError = nil
        error = nil
        return url
    }

    @MainActor
    public func checkConnection() async throws -> Bool {
        let operationEndpointGeneration = endpointGeneration
        let ollama = try configuredOllama()
        do {
            try await dependencies.checkConnection(ollama)
            try validateProbe(endpointGeneration: operationEndpointGeneration)
            return true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try validateProbe(endpointGeneration: operationEndpointGeneration)
            return false
        }
    }

    @MainActor
    private func validateProbe(endpointGeneration: UInt) throws {
        try Task.checkCancellation()
        guard self.endpointGeneration == endpointGeneration else {
            throw CancellationError()
        }
    }
}
