import Combine
import Foundation

/// Optional authoritative catalog for hosts with non-direct model access.
/// The default settings path continues to use ProviderAccessManager.
@MainActor
public final class ChatModelSource: ObservableObject {
    public enum State: Equatable {
        case direct
        case loading
        case authenticationRequired
        case ready([Model])
        case empty
        case failed(String)
        case unsupportedCatalog
    }

    @Published public private(set) var state: State
    /// Independent ollama/ollamaCloud models that remain available regardless of
    /// hosted-catalog state (loading, error, auth-needed, or ready).
    @Published public private(set) var independentModels: [Model] = []
    public var retry: () -> Void = {}
    public var signIn: () -> Void = {}

    public init(state: State = .loading) { self.state = state }

    public var isProxy: Bool { state != .direct }

    /// Hosted catalog models only (ordinary proxy providers).
    public var models: [Model] {
        guard case .ready(let models) = state else { return [] }
        return models
    }

    /// All visible models: hosted ready models + independent ollama/ollamaCloud.
    public var allModels: [Model] {
        var result = models
        for m in independentModels where !result.contains(m) {
            result.append(m)
        }
        return result
    }

    public func update(_ state: State) { self.state = state }

    /// Replace local/Cloud-specific independent models. Only ollama and ollamaCloud
    /// routes are accepted; ordinary hosted models are ignored.
    public func updateIndependentModels(_ models: [Model]) {
        independentModels = models.filter { m in
            if case .ollama = m { return true }
            if case .ollamaCloud = m { return true }
            return false
        }
    }

    /// Never replace a persisted ollama/ollamaCloud selection while loading,
    /// after failure, or when the hosted catalog does not include it.
    /// Ordinary hosted selections are reconciled to the first available model.
    public func reconciledSelection(_ selection: Model, state emittedState: State? = nil) -> Model {
        // Local ollama and ollamaCloud selections survive catalog state changes.
        if case .ollama = selection { return selection }
        if case .ollamaCloud = selection { return selection }
        guard case .ready(let models) = emittedState ?? state,
              !models.contains(selection), let first = models.first else { return selection }
        return first
    }
}
