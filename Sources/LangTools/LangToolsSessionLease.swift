import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Shared retirement ownership for an explicitly adopted URLSession.
/// Keep the same lease in every captured transport consumer. Releasing the final
/// lease finishes outstanding tasks and invalidates the session, releasing its
/// delegate. Merely retaining the raw session does not retain this lease.
public final class LangToolsSessionLease: @unchecked Sendable {
    public let session: URLSession

    /// Adopts retirement ownership. Create only one lease for a given session;
    /// default/shared sessions should not be adopted unless retirement is intended.
    public init(session: URLSession) {
        self.session = session
    }

    deinit {
        session.finishTasksAndInvalidate()
    }
}
