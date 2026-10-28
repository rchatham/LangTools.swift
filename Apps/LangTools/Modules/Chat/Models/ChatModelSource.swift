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
    public var retry: () -> Void = {}
    public var signIn: () -> Void = {}

    public init(state: State = .loading) { self.state = state }

    public var isProxy: Bool { state != .direct }
    public var models: [Model] {
        guard case .ready(let models) = state else { return [] }
        return models
    }

    public func update(_ state: State) { self.state = state }

    /// Never replace a persisted selection while loading or after failure.
    public func reconciledSelection(_ selection: Model) -> Model {
        guard case .ready(let models) = state,
              !models.contains(selection), let first = models.first else { return selection }
        return first
    }
}
