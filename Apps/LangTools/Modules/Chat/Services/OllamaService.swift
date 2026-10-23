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

    @Published var availableModels: [Ollama.Model] = []
    @Published var runningModels: [Ollama.ListRunningModelsResponse.RunningModelInfo] = []
    @Published var isLoading = false
    @Published public var error: Error?
    @Published public private(set) var transportRevision: UInt64 = 0

    public let endpointConfiguration: OllamaEndpointConfiguration
    private let session: URLSession
    private let providerAccessManager: ProviderAccessManager
    private var refreshGeneration: UInt64 = 0
    private var accountTransportSubscription: AnyCancellable?

    public init(
        endpointConfiguration: OllamaEndpointConfiguration = .shared,
        session: URLSession = .shared,
        providerAccessManager: ProviderAccessManager = .shared
    ) {
        self.endpointConfiguration = endpointConfiguration
        self.session = session
        self.providerAccessManager = providerAccessManager
        availableModels = endpointConfiguration.cachedModels()
        transportRevision = endpointConfiguration.snapshot().revision
        accountTransportSubscription = NotificationCenter.default.publisher(for: AccountTransportSelectionStore.didChange,
            object: providerAccessManager.accountTransports)
            .sink { [weak self] _ in
                guard let self, self.transportRevision != self.endpointConfiguration.snapshot().revision else { return }
                self.transportDidChange()
            }
    }

    /// Retire every selected capability of this device, not just the Ollama UI.
    public func disconnectHelper() throws {
        var firstError: Error?
        if let id = endpointConfiguration.snapshot().helperID,
           providerAccessManager.accountTransports.registeredHelperID == id {
            do { try providerAccessManager.accountTransports.disconnectHelper() } catch { firstError = error }
        }
        do { try endpointConfiguration.disconnectHelper() } catch { if firstError == nil { firstError = error } }
        transportDidChange()
        if let firstError { throw firstError }
    }

    public func refreshModels() {
        let snapshot = endpointConfiguration.snapshot()
        refreshGeneration &+= 1
        let generation = refreshGeneration
        isLoading = true
        error = nil

        Task {
            do {
                let provider = try provider(for: snapshot)
                let response = try await provider.listModels()
                let models = response.models.compactMap { Ollama.Model(rawValue: $0.name) }
                let runningResponse = try? await provider.listRunningModels()
                let discoveredRunningModels = runningResponse?.models ?? []

                guard endpointConfiguration.isCurrent(snapshot), generation == refreshGeneration else { return }
                availableModels = models
                runningModels = discoveredRunningModels
                isLoading = false
                if endpointConfiguration.storeModels(models, for: snapshot) {
                    providerAccessManager.refresh()
                }
            } catch {
                guard endpointConfiguration.isCurrent(snapshot), generation == refreshGeneration else { return }
                self.error = snapshot.isHelper ? MobileHelperError.actionable(error, session: snapshot.helper?.session) : error
                isLoading = false
            }
        }
    }

    @discardableResult
    public func updateEndpoint(_ value: String) throws -> OllamaEndpointConfiguration.Snapshot {
        let snapshot = try endpointConfiguration.update(value)
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
        let provider = try provider(for: capturedSnapshot)
        for try await response in provider.streamPullModel(modelName) {
            if let total = response.total, let completed = response.completed, total > 0 {
                progressHandler(Double(completed) / Double(total))
            }
        }

        if endpointConfiguration.isCurrent(capturedSnapshot) {
            refreshModels()
        }
    }

    func loadModel(
        _ model: Ollama.Model,
        for snapshot: OllamaEndpointConfiguration.Snapshot? = nil
    ) async throws {
        let capturedSnapshot = snapshot ?? endpointConfiguration.snapshot()
        let provider = try provider(for: capturedSnapshot)
        _ = try await provider.chat(
            model: model,
            messages: [Ollama.Message(role: .user, content: "Hello")]
        )

        if endpointConfiguration.isCurrent(capturedSnapshot) {
            refreshModels()
        }
    }

    public func checkConnection(
        for snapshot: OllamaEndpointConfiguration.Snapshot? = nil
    ) async throws {
        let capturedSnapshot = snapshot ?? endpointConfiguration.snapshot()
        do {
            if let helper = capturedSnapshot.helper {
                try await MobileHelperPairingClient.verifyHealth(credential: helper.credential, session: helper.session, requiredCapability: "ollama")
            }
            _ = try await provider(for: capturedSnapshot).version()
        } catch { throw capturedSnapshot.isHelper ? MobileHelperError.actionable(error, session: capturedSnapshot.helper?.session) : error }
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

    private func provider(for snapshot: OllamaEndpointConfiguration.Snapshot) throws -> Ollama {
        try snapshot.provider(directSession: session)
    }
}
