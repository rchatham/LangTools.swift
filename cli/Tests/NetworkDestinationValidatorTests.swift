import XCTest
@testable import CLI

final class NetworkDestinationValidatorTests: XCTestCase {
    func testRejectsLocalAndPrivateDestinations() {
        let blocked = [
            "https://localhost",
            "https://127.0.0.1",
            "https://10.0.0.1",
            "https://172.16.0.1",
            "https://192.168.1.1",
            "https://169.254.169.254",
            "https://198.51.100.1",
            "https://203.0.113.1",
            "https://[::1]",
            "https://[fe80::1]",
            "https://[fc00::1]"
        ]

        for value in blocked {
            XCTAssertThrowsError(try NetworkDestinationValidator.validate(url: XCTUnwrap(URL(string: value))), value)
        }
    }

    func testPublicAddressesAreAllowed() throws {
        try NetworkDestinationValidator.validate(url: XCTUnwrap(URL(string: "https://8.8.8.8")))
        try NetworkDestinationValidator.validate(url: XCTUnwrap(URL(string: "https://[2606:4700:4700::1111]")))
    }

    func testRejectsNonHTTPSURLs() throws {
        XCTAssertThrowsError(
            try NetworkDestinationValidator.validate(url: XCTUnwrap(URL(string: "http://8.8.8.8")))
        )
    }

    func testFetchPinsConnectionToAddressFromValidationPass() async throws {
        let resolver = StubResolver(results: [["93.184.216.34"], ["127.0.0.1"]])
        let transport = RecordingTransport(responses: [(Data("ok".utf8), try response(url: "https://example.com", status: 200))])

        _ = try await WebFetchTool.fetchData(
            from: XCTUnwrap(URL(string: "https://example.com")),
            resolver: resolver,
            transport: transport
        )

        XCTAssertEqual(resolver.callCount, 1)
        XCTAssertEqual(transport.pinnedAddresses, ["93.184.216.34"])
    }

    func testRedirectIsValidatedBeforeSecondConnection() async throws {
        let resolver = StubResolver(results: [["93.184.216.34"], ["169.254.169.254"]])
        let redirect = try response(url: "https://example.com", status: 302, headers: ["Location": "https://metadata.example/latest"])
        let transport = RecordingTransport(responses: [(Data(), redirect)])

        do {
            _ = try await WebFetchTool.fetchData(
                from: XCTUnwrap(URL(string: "https://example.com")),
                resolver: resolver,
                transport: transport
            )
            XCTFail("Expected private redirect to be rejected")
        } catch {
            XCTAssertEqual(transport.pinnedAddresses, ["93.184.216.34"])
        }
    }

    private func response(url: String, status: Int, headers: [String: String]? = nil) throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(URL(string: url)), statusCode: status, httpVersion: nil, headerFields: headers))
    }
}

private final class StubResolver: NetworkAddressResolving {
    private let results: [[String]]
    private(set) var callCount = 0

    init(results: [[String]]) { self.results = results }

    func addresses(for host: String) throws -> [String] {
        defer { callCount += 1 }
        return results[min(callCount, results.count - 1)]
    }
}

private final class RecordingTransport: PinnedHTTPSTransport {
    private let responses: [(Data, HTTPURLResponse)]
    private(set) var pinnedAddresses: [String] = []

    init(responses: [(Data, HTTPURLResponse)]) { self.responses = responses }

    func fetch(url: URL, pinnedAddress: String) async throws -> (Data, HTTPURLResponse) {
        pinnedAddresses.append(pinnedAddress)
        return responses[min(pinnedAddresses.count - 1, responses.count - 1)]
    }
}
