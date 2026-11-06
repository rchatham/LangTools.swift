//
//  OllamaService.swift
//
//  Created by Reid Chatham on 2/25/25.
//

import Combine
import Foundation
import LangTools
import Ollama

@MainActor
public final class OllamaService: ObservableObject {
    public static let shared = OllamaService()

    @Published public var availableModels: [Ollama.Model] = []
    @Published var runningModels: [Ollama.ListRunningModelsResponse.RunningModelInfo] = []
    @Published var isLoading = false
    @Published public var error: Error?
    @Published public private(set) var transportRevision: UInt64 = 0

    public let endpointConfiguration: OllamaEndpointConfiguration
    private let session: URLSession?
    private let providerAccessManager: ProviderAccessManager
    private var refreshGeneration: UInt64 = 0

    public init(
        endpointConfiguration: OllamaEndpointConfiguration = .shared,
        session: URLSession? = nil,
        providerAccessManager: ProviderAccessManager = .shared
    ) {
        self.endpointConfiguration = endpointConfiguration
        self.session = session
        self.providerAccessManager = providerAccessManager
        availableModels = endpointConfiguration.cachedModels()
        transportRevision = endpointConfiguration.snapshot().revision
        error = endpointConfiguration.snapshot().validationError
    }

    public func refreshModels() {
        let snapshot = endpointConfiguration.snapshot()
        refreshGeneration &+= 1
        let generation = refreshGeneration
        isLoading = true
        error = snapshot.validationError
        if snapshot.cacheScope == nil {
            availableModels = []
            runningModels = []
        }

        Task {
            do {
                try requireCurrent(snapshot)
                let provider = try provider(for: snapshot)
                let response = try await provider.listModels()
                try requireCurrent(snapshot)
                guard generation == refreshGeneration else { return }
                let models = response.models.compactMap { Ollama.Model(rawValue: $0.name) }
                let discoveredRunningModels: [Ollama.ListRunningModelsResponse.RunningModelInfo]
                do { discoveredRunningModels = try await provider.listRunningModels().models }
                catch {
                    try requireCurrent(snapshot)
                    // Model discovery remains useful when optional running-model discovery fails.
                    discoveredRunningModels = []
                }
                try requireCurrent(snapshot)
                guard generation == refreshGeneration else { return }
                availableModels = models
                runningModels = discoveredRunningModels
                isLoading = false
                if endpointConfiguration.storeModels(models, for: snapshot) {
                    providerAccessManager.refresh()
                }
            } catch {
                guard endpointConfiguration.isCurrent(snapshot), generation == refreshGeneration else { return }
                isLoading = false
                guard !(error is CancellationError), !Task.isCancelled else { return }
                self.error = snapshot.actionableError(error)
            }
        }
    }

    @discardableResult
    public func updateEndpoint(_ value: String) throws -> OllamaEndpointConfiguration.Snapshot {
        let previous = endpointConfiguration.snapshot()
        let snapshot = try endpointConfiguration.update(value)
        guard snapshot != previous else { return snapshot }
        transportRevision = snapshot.revision
        refreshGeneration &+= 1
        availableModels = []
        runningModels = []
        isLoading = false
        error = nil
        providerAccessManager.refresh()
        refreshModels()
        return snapshot
    }

    func pullModel(
        _ modelName: String,
        for snapshot: OllamaEndpointConfiguration.Snapshot? = nil,
        progressHandler: @escaping (Double) -> Void
    ) async throws {
        let capturedSnapshot = snapshot ?? endpointConfiguration.snapshot()
        try Task.checkCancellation()
        let provider = try provider(for: capturedSnapshot)
        for try await response in provider.streamPullModel(modelName) {
            try Task.checkCancellation()
            if let total = response.total, let completed = response.completed, total > 0 {
                progressHandler(Double(completed) / Double(total))
            }
        }

        try Task.checkCancellation()
        if endpointConfiguration.isCurrent(capturedSnapshot) {
            refreshModels()
        }
    }

    func loadModel(
        _ model: Ollama.Model,
        for snapshot: OllamaEndpointConfiguration.Snapshot? = nil
    ) async throws {
        let capturedSnapshot = snapshot ?? endpointConfiguration.snapshot()
        try Task.checkCancellation()
        let provider = try provider(for: capturedSnapshot)
        _ = try await provider.chat(
            model: model,
            messages: [Ollama.Message(role: .user, content: "Hello")]
        )

        try Task.checkCancellation()
        if endpointConfiguration.isCurrent(capturedSnapshot) {
            refreshModels()
        }
    }

    public func checkConnection(
        for snapshot: OllamaEndpointConfiguration.Snapshot? = nil
    ) async throws {
        let capturedSnapshot = snapshot ?? endpointConfiguration.snapshot()
        try requireCurrent(capturedSnapshot)
        do {
            let provider = try provider(for: capturedSnapshot)
            if let helper = capturedSnapshot.helper {
                try await MobileHelperPairingClient.verifyHealth(credential: helper.credential, session: helper.session)
                try requireCurrent(capturedSnapshot)
            }
            _ = try await provider.version()
            try requireCurrent(capturedSnapshot)
        } catch {
            try requireCurrent(capturedSnapshot)
            throw capturedSnapshot.actionableError(error)
        }
    }

    public func transportDidChange() {
        transportRevision = endpointConfiguration.snapshot().revision
        refreshGeneration &+= 1
        availableModels = endpointConfiguration.cachedModels()
        runningModels = []
        error = nil
        providerAccessManager.refresh()
        refreshModels()
    }

    private func requireCurrent(_ snapshot: OllamaEndpointConfiguration.Snapshot) throws {
        try Task.checkCancellation()
        guard endpointConfiguration.isCurrent(snapshot) else { throw CancellationError() }
    }

    private func provider(for snapshot: OllamaEndpointConfiguration.Snapshot) throws -> Ollama {
        try snapshot.provider(directSession: session ?? snapshot.directSession)
    }
}
