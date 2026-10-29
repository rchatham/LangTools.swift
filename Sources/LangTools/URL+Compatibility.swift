import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// URL methods compatibility for Linux
// These methods are Darwin-only in Swift < 6.0, but became available on all platforms in Swift 6.0
#if !canImport(Darwin)
#if compiler(<6.0)
extension URL {
    /// Compatibility method for appending(path:) on Linux with Swift < 6.0
    public func appending(path: String) -> URL {
        return appendingPathComponent(path)
    }

    /// Compatibility method for appending(queryItems:) on Linux with Swift < 6.0
    public func appending(queryItems: [URLQueryItem]) -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return self
        }
        components.queryItems = queryItems
        return components.url ?? self
    }

    /// Compatibility initializer for URL(filePath:) on Linux with Swift < 6.0
    public init(filePath: String) {
        self.init(fileURLWithPath: filePath)
    }
}
#endif
#endif
