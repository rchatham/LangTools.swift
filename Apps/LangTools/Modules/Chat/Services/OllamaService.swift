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
    @Published public var error: Error? {
        willSet {
            let assignment = UUID()
            errorAssignmentStack.append(assignment)
            latestErrorAssignment = (assignment, newValue)
            // Consume the permit BEFORE @Published invokes synchronous subscribers.
            // A subscriber's nested public assignment must invalidate pending claims.
            if claimedErrorAssignment {
                claimedErrorAssignment = false
            } else {
                invalidateErrorPublications()
            }
        }
        didSet {
            let completed = errorAssignmentStack.removeLast()
            guard errorAssignmentStack.isEmpty, let latest = latestErrorAssignment else { return }
            latestErrorAssignment = nil
            // @Published stores AFTER invoking subscribers. A nested assignment
            // would otherwise be overwritten by the outer setter on its return.
            // Replay the last assignment without invalidating its newer claim.
            if completed != latest.id { assignClaimedError(latest.value) }
        }
    }
    @Published public private(set) var transportRevision: UInt64 = 0

    public let endpointConfiguration: OllamaEndpointConfiguration
    private let session: URLSession
    private let providerAccessManager: ProviderAccessManager
    private var refreshGeneration: UInt64 = 0
    private let errorPublicationOwner = UUID()
    private var errorPublicationID = UUID()
    private var claimedErrorAssignment = false
    private var errorAssignmentStack: [UUID] = []
    private var latestErrorAssignment: (id: UUID, value: Error?)?

    /// Opaque capability for the latest error-producing operation on this service.
    /// Model/cache/loading generations are intentionally independent of this domain.
    public struct ErrorPublicationClaim {
        fileprivate let owner: UUID
        fileprivate let id: UUID
    }

    public func beginErrorPublication(clearError: Bool = true) -> ErrorPublicationClaim {
        errorPublicationID = UUID()
        let claim = ErrorPublicationClaim(owner: errorPublicationOwner, id: errorPublicationID)
        if clearError { publishError(nil, for: claim) }
        return claim
    }

    public func isCurrentErrorPublication(_ claim: ErrorPublicationClaim) -> Bool {
        claim.owner == errorPublicationOwner && claim.id == errorPublicationID
    }

    /// Returns whether this assignment was accepted. Synchronous subscribers may
    /// supersede the claim during publication; callers must recheck before more work.
    @discardableResult
    public func publishError(_ value: Error?, for claim: ErrorPublicationClaim) -> Bool {
        guard isCurrentErrorPublication(claim) else { return false }
        assignClaimedError(value)
        return true
    }

    private func assignClaimedError(_ value: Error?) {
        claimedErrorAssignment = true
        error = value
    }

    public func invalidateErrorPublications() {
        errorPublicationID = UUID()
    }

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
    }

    public func refreshModels() {
        let snapshot = endpointConfiguration.snapshot()
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let errorClaim = beginErrorPublication()
        isLoading = true

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
                publishError(nil, for: errorClaim)
            } catch {
                guard endpointConfiguration.isCurrent(snapshot), generation == refreshGeneration else { return }
                isLoading = false
                publishError(snapshot.isHelper ? MobileHelperError.actionable(error, session: snapshot.helper?.session) : error,
                    for: errorClaim)
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
                try await MobileHelperPairingClient.verifyHealth(credential: helper.credential, session: helper.session)
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
