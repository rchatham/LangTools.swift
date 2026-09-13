import Foundation
import XCTest
@testable import LangToolsCLI

final class CodexAppServerProtocolTests: XCTestCase {
    func testRecursiveJSONValueRoundTrips() throws {
        let value: JSONValue = .object([
            "null": .null,
            "bool": .bool(true),
            "number": .number(2.5),
            "string": .string("value"),
            "array": .array([.number(1), .object(["nested": .string("yes")])])
        ])

        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)), value)
    }

    func testInitializeAndInitializedMatchSchema() throws {
        let params = CodexInitializeParams(
            clientInfo: .init(name: "langtools-cli", title: "LangTools CLI", version: "1"),
            capabilities: .init(
                experimentalApi: false,
                requestAttestation: false,
                mcpServerOpenaiFormElicitation: false,
                optOutNotificationMethods: nil
            )
        )
        let request = CodexRequestEnvelope(id: .integer(1), method: "initialize", params: params)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(object["method"] as? String, "initialize")
        XCTAssertNil(object["jsonrpc"])
        let encodedParams = try XCTUnwrap(object["params"] as? [String: Any])
        XCTAssertNotNil(encodedParams["clientInfo"])

        let initialized = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(#"{"method":"initialized"}"#.utf8)) as? [String: Any])
        XCTAssertEqual(initialized.count, 1)
    }

    func testLoginAccountAndModelPaginationDecodeExactFields() throws {
        let login = try JSONDecoder().decode(
            CodexLoginAccountResponse.self,
            from: Data(#"{"type":"chatgpt","loginId":"login-1","authUrl":"https://example.invalid/login"}"#.utf8)
        )
        guard case .chatgpt(let loginID, let authURL) = login else {
            return XCTFail("Expected ChatGPT login response")
        }
        XCTAssertEqual(loginID, "login-1")
        XCTAssertEqual(authURL, "https://example.invalid/login")

        let page = try JSONDecoder().decode(
            CodexModelListResponse.self,
            from: Data(#"{"data":[{"id":"gpt-codex","model":"provider-model","displayName":"Codex","description":"Test","hidden":false,"isDefault":true}],"nextCursor":"cursor-2"}"#.utf8)
        )
        XCTAssertEqual(page.data.first?.id, "gpt-codex")
        XCTAssertEqual(page.nextCursor, "cursor-2")
    }

    func testThreadTurnDeltaCompletionAndInterruptUseExactKeys() throws {
        let thread = CodexThreadStartParams(
            model: "gpt-codex",
            modelProvider: nil,
            cwd: "/tmp/isolated",
            approvalPolicy: "never",
            sandbox: "read-only",
            config: nil,
            developerInstructions: nil,
            multiAgentMode: "none",
            ephemeral: true,
            environments: [],
            dynamicTools: [],
            selectedCapabilityRoots: []
        )
        let threadObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(thread)) as? [String: Any])
        XCTAssertEqual(threadObject["sandbox"] as? String, "read-only")
        XCTAssertEqual(threadObject["approvalPolicy"] as? String, "never")

        let turn = CodexTurnStartParams(
            threadId: "thread-1",
            input: [.init(text: "hello")],
            approvalPolicy: "never",
            sandboxPolicy: ReadOnlySandboxPolicy(),
            model: "gpt-codex",
            environments: [],
            multiAgentMode: "none"
        )
        let turnObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(turn)) as? [String: Any])
        let input = try XCTUnwrap((turnObject["input"] as? [[String: Any]])?.first)
        XCTAssertNotNil(input["text_elements"])

        let delta = try JSONDecoder().decode(
            CodexAgentMessageDeltaNotification.self,
            from: Data(#"{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","delta":"hi"}"#.utf8)
        )
        XCTAssertEqual(delta.delta, "hi")

        let completed = try JSONDecoder().decode(
            CodexTurnCompletedNotification.self,
            from: Data(#"{"threadId":"thread-1","turn":{"id":"turn-1","status":"completed","error":null}}"#.utf8)
        )
        XCTAssertEqual(completed.turn.status, "completed")

        let interrupt = CodexTurnInterruptParams(threadId: "thread-1", turnId: "turn-1")
        let interruptObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(interrupt)) as? [String: Any])
        XCTAssertEqual(interruptObject["turnId"] as? String, "turn-1")
    }
}
