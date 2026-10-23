//
//  URLSessionShimTests.swift
//  LangToolsTests
//
//  The FoundationNetworking streaming shim (URLSession+AsyncBytes.swift).
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LangTools

final class URLSessionShimTests: XCTestCase {
    #if !canImport(Darwin)
    func testAlreadyCancelledRequestFailsWithoutStarting() async {
        let task = Task { () -> Error? in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                // Never sent: the shim checks for cancellation before starting the task.
                _ = try await URLSession(configuration: .ephemeral).data(for: URLRequest(url: URL(string: "https://example.invalid/")!))
                return nil
            } catch {
                return error
            }
        }

        let error = await task.value

        XCTAssertEqual((error as? URLError)?.code, .cancelled, "\(String(describing: error))")
    }
    #endif
}
