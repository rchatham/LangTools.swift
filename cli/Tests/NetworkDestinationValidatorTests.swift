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

    func testRedirectDelegateRejectsPrivateDestination() throws {
        let delegate = SafeRedirectDelegate()
        let originalURL = try XCTUnwrap(URL(string: "https://8.8.8.8"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: originalURL,
            statusCode: 302,
            httpVersion: nil,
            headerFields: nil
        ))
        let request = URLRequest(url: try XCTUnwrap(URL(string: "https://169.254.169.254/latest/meta-data")))
        let expectation = expectation(description: "redirect decision")

        delegate.urlSession(URLSession.shared, task: URLSession.shared.dataTask(with: originalURL), willPerformHTTPRedirection: response, newRequest: request) { redirectedRequest in
            XCTAssertNil(redirectedRequest)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1)
    }
}
