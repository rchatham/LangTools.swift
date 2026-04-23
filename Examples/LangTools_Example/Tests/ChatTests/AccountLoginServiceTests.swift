import XCTest
@testable import Chat

final class AccountLoginServiceTests: XCTestCase {
    func testStubOpenAILoginIncludesCodexModels() async throws {
        let service = StubAccountLoginService()

        let session = try await service.beginLogin(for: .openAI)

        XCTAssertEqual(session.provider, .openAI)
        XCTAssertTrue(session.accessibleModelIDs.contains("gpt-5.1-codex"))
    }

    func testStubClaudeCodeLoginMapsToAnthropicModels() async throws {
        let service = StubAccountLoginService()

        let session = try await service.beginLogin(for: .claudeCode)

        XCTAssertEqual(session.provider, .claudeCode)
        XCTAssertTrue(session.accessibleModelIDs.contains(where: { $0.hasPrefix("claude-") }))
    }
}
