import Foundation
import XCTest
@testable import LangToolsCLI

final class CodexRuntimeServiceTests: XCTestCase {
    func testAccountModelsAndImmediateTurnDeltasUseNonLossySubscription() async throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("langtools-runtime-test-\(UUID().uuidString).py")
        try Data(Self.fakeServer.utf8).write(to: scriptURL)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let client = CodexAppServerClient(
            commandResolver: {
                ResolvedCodexCommand(executable: "/usr/bin/python3", arguments: ["-u", scriptURL.path])
            },
            defaultTimeout: .seconds(5)
        )
        let runtime = CodexRuntimeService(client: client, browserOpener: { _ in })

        let status = try await runtime.accountStatus()
        XCTAssertTrue(status.authenticated)
        XCTAssertEqual(status.accountIdentifier, "person@example.com")
        let models = try await runtime.modelSlugs()
        let response = try await runtime.chat(model: "codex-one", messages: [.init(role: "user", content: "Hello")])
        XCTAssertEqual(models, ["codex-one", "codex-two"])
        XCTAssertEqual(response, (0..<150).map { "\($0)," }.joined())
        await runtime.shutdown()
    }

    private static let fakeServer = #"""
import json
import sys

def read():
    return json.loads(sys.stdin.readline())

def write(value):
    print(json.dumps(value), flush=True)

def model(id, model):
    return {"id": id, "model": model, "displayName": id, "description": "test", "hidden": False, "isDefault": False}

initialize = read()
write({"id": initialize["id"], "result": {"userAgent":"fake", "codexHome":"/tmp", "platformFamily":"unix", "platformOs":"macos"}})
assert read()["method"] == "initialized"

while True:
    request = read()
    method = request["method"]
    if method == "account/read":
        write({"id":request["id"], "result":{"account":{"type":"chatgpt","email":"person@example.com","planType":"plus"},"requiresOpenaiAuth":False}})
    elif method == "model/list":
        cursor = request["params"].get("cursor")
        if cursor is None:
            write({"id":request["id"], "result":{"data":[model(" codex-one ", "provider-one"), model("codex-one", "duplicate")],"nextCursor":"page-2"}})
        else:
            assert cursor == "page-2"
            write({"id":request["id"], "result":{"data":[model("codex-two", "provider-two")],"nextCursor":None}})
    elif method == "thread/start":
        params = request["params"]
        assert params["model"] == "codex-one"
        assert params["approvalPolicy"] == "never"
        assert params["sandbox"] == "read-only"
        assert params["ephemeral"] is True
        assert params["dynamicTools"] == []
        assert params["environments"] == []
        assert params["config"]["web_search"] == "disabled"
        assert params["config"]["tools"]["web_search"] is None
        write({"id":request["id"], "result":{"thread":{"id":"thread-1"},"model":"codex-one","modelProvider":"openai"}})
    elif method == "turn/start":
        params = request["params"]
        assert params["threadId"] == "thread-1"
        assert params["sandboxPolicy"] == {"type":"readOnly","networkAccess":False}
        assert params["input"][0]["text_elements"] == []
        for index in range(75):
            write({"method":"item/agentMessage/delta","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"a","delta":str(index) + ","}})
        write({"id":request["id"], "result":{"turn":{"id":"turn-1"}}})
        write({"method":"item/agentMessage/delta","params":{"threadId":"other","turnId":"other","itemId":"x","delta":"ignore"}})
        for index in range(75, 150):
            write({"method":"item/agentMessage/delta","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"a","delta":str(index) + ","}})
        write({"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","status":"completed","error":None}}})
    else:
        write({"id":request["id"], "error":{"code":-32601,"message":"unexpected " + method}})
"""#
}
