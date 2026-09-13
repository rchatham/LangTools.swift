import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools
@testable import Ollama

final class OllamaCloudIntegrationTests: XCTestCase {
    func testCloudChat() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LANGTOOLS_RUN_OLLAMA_CLOUD_TESTS"] == "1" else {
            throw XCTSkip("Set LANGTOOLS_RUN_OLLAMA_CLOUD_TESTS=1 to run the live Ollama Cloud smoke test")
        }
        guard let apiKey = environment["OLLAMA_API_KEY"], !apiKey.isEmpty else {
            XCTFail("OLLAMA_API_KEY is required when live Ollama Cloud tests are enabled")
            return
        }

        let baseURLString = environment["OLLAMA_CLOUD_BASE_URL"] ?? "https://ollama.com"
        guard let baseURL = URL(string: baseURLString), baseURL.scheme == "https",
              let host = baseURL.host, !host.isEmpty,
              baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil else {
            XCTFail("OLLAMA_CLOUD_BASE_URL must be a valid HTTPS URL")
            return
        }

        let modelID = environment["OLLAMA_CLOUD_MODEL"] ?? "glm-5.2"
        guard let model = OllamaModel(rawValue: modelID) else {
            XCTFail("OLLAMA_CLOUD_MODEL is not a valid Ollama model identifier")
            return
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let api = Ollama(baseURL: baseURL, apiKey: apiKey, session: session)
        let response = try await api.chat(
            model: model,
            messages: [.init(role: .user, content: "Reply with exactly: pong")]
        )

        XCTAssertTrue(response.done)
        XCTAssertFalse(response.message?.content.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}
