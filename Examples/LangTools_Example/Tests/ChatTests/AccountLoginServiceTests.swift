import XCTest
@testable import Chat

final class AccountLoginServiceTests: XCTestCase {
    func testStubOpenAILoginReportsNotImplemented() async throws {
        let service = StubAccountLoginService()

        do {
            _ = try await service.beginLogin(for: .openAI)
            XCTFail("Expected beginLogin to throw")
        } catch {
            XCTAssertEqual(error as? AccountLoginError, .notImplemented(.openAI))
        }
    }

    func testStubClaudeCodeLoginReportsNotImplemented() async throws {
        let service = StubAccountLoginService()

        do {
            _ = try await service.beginLogin(for: .claudeCode)
            XCTFail("Expected beginLogin to throw")
        } catch {
            XCTAssertEqual(error as? AccountLoginError, .notImplemented(.claudeCode))
        }
    }

    func testStubOpenAIModelFetchIncludesCodexModels() async throws {
        let service = StubAccountLoginService()

        let models = try await service.fetchAccessibleModels(for: .openAI)

        XCTAssertTrue(models.contains("gpt-5.1-codex"))
    }

    func testStubClaudeModelFetchMapsToAnthropicModels() async throws {
        let service = StubAccountLoginService()

        let models = try await service.fetchAccessibleModels(for: .claudeCode)

        XCTAssertTrue(models.contains(where: { $0.hasPrefix("claude-") }))
    }
}
