import XCTest
@testable import HelperLink

final class MobileHelperModelsTests: XCTestCase {
    private var payload: MobileHelperPairingPayload {
        .init(endpoint: URL(string: "https://192.168.1.20:8086")!, helperID: UUID().uuidString,
              fingerprint: String(repeating: "a", count: 64), code: String(repeating: "b", count: 64), name: "Reid’s Mac")
    }
    func testStrictRoundTrip() throws {
        let value = payload
        XCTAssertEqual(try MobileHelperPairingPayload.parse(value.pairingURL()), value)
        XCTAssertEqual(try JSONDecoder().decode(MobileHelperPairingPayload.self, from: JSONEncoder().encode(value)), value)
    }
    func testRejectsDuplicateMissingUnknownAndVersion() throws {
        let text = try payload.pairingURL().absoluteString
        for invalid in [text + "&v=1", text + "&token=secret", text.replacingOccurrences(of: "v=1", with: "v=2"),
                        text.replacingOccurrences(of: "&name=", with: "&unknown=")] {
            XCTAssertThrowsError(try MobileHelperPairingPayload.parse(URL(string: invalid)!))
        }
    }
    func testRejectsUnsafeEndpointsAndFields() {
        for endpoint in ["http://192.168.1.2:8086", "https://localhost:8086", "https://127.0.0.1:8086",
                         "https://8.8.8.8:8086", "https://192.168.1.2:8086/api", "https://user@192.168.1.2:8086",
                         "https://192.168.1.2:8086?x=1", "https://192.168.1.2:8086#x", "https://192.168.1.2"] {
            let original = payload
            XCTAssertThrowsError(try MobileHelperPairingPayload(endpoint: URL(string: endpoint)!, helperID: original.helperID,
                fingerprint: original.fingerprint, code: original.code, name: original.name).validate())
        }
        XCTAssertFalse(MobileHelperPairingPayload.isHexSecret(String(repeating: "A", count: 64)))
        XCTAssertFalse(MobileHelperPairingPayload.isPrivateIPv4("010.1.1.1"))
        XCTAssertFalse(MobileHelperPairingPayload.isDisplayName("Mac\nToken"))
        XCTAssertFalse(MobileHelperPairingPayload.isDisplayName(String(repeating: "m", count: 129)))
    }
    func testPrivateIPv4DoesNotAssume24BitSubnet() throws {
        // These suffixes are valid host addresses with, for example, a /23 netmask.
        for host in ["192.168.1.255", "192.168.2.0", "10.1.1.255", "172.16.2.0", "169.254.1.255"] {
            XCTAssertTrue(MobileHelperPairingPayload.isPrivateIPv4(host), host)
            let original = payload
            let value = MobileHelperPairingPayload(endpoint: URL(string: "https://\(host):8086")!,
                helperID: original.helperID, fingerprint: original.fingerprint, code: original.code, name: original.name)
            XCTAssertEqual(try MobileHelperPairingPayload.parse(value.pairingURL()), value)
        }
        for host in ["127.0.0.1", "8.8.8.255", "172.15.1.255", "172.32.2.0", "169.254.0.1",
                     "169.254.255.1", "224.1.1.255", "255.255.255.255", "192.168.01.255"] {
            XCTAssertFalse(MobileHelperPairingPayload.isPrivateIPv4(host), host)
        }
    }

    func testDecodedWireValuesCannotBypassValidation() throws {
        let good = MobileHelperPairingResponse(helperID: UUID().uuidString, deviceID: UUID().uuidString, token: String(repeating: "c", count: 64))
        let data = try JSONEncoder().encode(good)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for (key, invalid) in [("version", 2 as Any), ("helperID", "bad" as Any), ("deviceID", "bad" as Any),
                               ("token", "short" as Any), ("capabilities", ["ollama", "account"] as Any), ("extra", true as Any)] {
            var changed = object
            changed[key] = invalid
            XCTAssertThrowsError(try JSONDecoder().decode(MobileHelperPairingResponse.self, from: JSONSerialization.data(withJSONObject: changed)))
        }
        for json in [#"{"code":"bad","name":"Phone"}"#, #"{"code":"bad","name":"Phone","token":"desktop"}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(MobileHelperPairingRequest.self, from: Data(json.utf8)))
        }
        let original = payload
        var decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        decoded["endpoint"] = "http://127.0.0.1:8086"
        XCTAssertThrowsError(try JSONDecoder().decode(MobileHelperPairingPayload.self, from: JSONSerialization.data(withJSONObject: decoded)))
        for scopes in [[], ["account"], ["ollama", "ollama"]] {
            let health = MobileHelperHealthResponse(helperID: UUID().uuidString, capabilities: scopes)
            XCTAssertThrowsError(try JSONDecoder().decode(MobileHelperHealthResponse.self, from: JSONEncoder().encode(health)))
        }
    }

    func testWireNamesAndCapabilityScope() throws {
        let response = MobileHelperPairingResponse(helperID: UUID().uuidString, deviceID: UUID().uuidString, token: String(repeating: "c", count: 64))
        XCTAssertEqual(response.capabilities, ["ollama"])
        XCTAssertEqual(try JSONDecoder().decode(MobileHelperPairingResponse.self, from: JSONEncoder().encode(response)), response)
    }

    func testCapabilitySetValidationRules() {
        XCTAssertTrue(MobileHelperCapabilities.isValid(["ollama"]))
        XCTAssertTrue(MobileHelperCapabilities.isValid(["claude"]))
        XCTAssertTrue(MobileHelperCapabilities.isValid(["codex", "ollama"]))
        XCTAssertTrue(MobileHelperCapabilities.isValid(["claude", "codex", "ollama"]))
        for invalid in [[String](), ["ollama", "ollama"], ["ollama", "account"], ["ollama", "claude"],
                        ["claude", "claude", "codex"], ["Ollama"], ["ollama", "codex"]] {
            XCTAssertFalse(MobileHelperCapabilities.isValid(invalid), "\(invalid)")
        }
        XCTAssertEqual(MobileHelperCapability.allCases.map(\.rawValue).sorted(), ["claude", "codex", "ollama"])
    }

    func testPairingAndHealthRoundTripWithGeneralizedCapabilitySets() throws {
        let granted = ["claude", "codex", "ollama"]
        let response = MobileHelperPairingResponse(helperID: UUID().uuidString, deviceID: UUID().uuidString,
            token: String(repeating: "c", count: 64), capabilities: granted)
        XCTAssertEqual(response.capabilities, granted)
        XCTAssertEqual(try JSONDecoder().decode(MobileHelperPairingResponse.self, from: JSONEncoder().encode(response)), response)
        let health = MobileHelperHealthResponse(helperID: UUID().uuidString, capabilities: granted)
        XCTAssertEqual(try JSONDecoder().decode(MobileHelperHealthResponse.self, from: JSONEncoder().encode(health)), health)
        // Version skew: the pre-generalization validate() rejected every set beyond ["ollama"],
        // so helpers keep advertising only the capabilities they actually serve.
        XCTAssertEqual(MobileHelperPairingResponse(helperID: UUID().uuidString, deviceID: UUID().uuidString,
            token: String(repeating: "c", count: 64)).capabilities, ["ollama"])
        XCTAssertEqual(MobileHelperHealthResponse(helperID: UUID().uuidString).capabilities, ["ollama"])
    }

    func testDecodingRejectsInvalidCapabilitySetsWhileKeepingStrictKeys() throws {
        let valid = try JSONEncoder().encode(MobileHelperPairingResponse(helperID: UUID().uuidString,
            deviceID: UUID().uuidString, token: String(repeating: "c", count: 64), capabilities: ["codex", "ollama"]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        for capabilities in [[Any](), ["ollama", "ollama"] as [Any], ["ollama", "claude"] as [Any], ["ollama", "account"] as [Any]] {
            var changed = object
            changed["capabilities"] = capabilities
            let data = try XCTUnwrap(JSONSerialization.data(withJSONObject: changed))
            XCTAssertThrowsError(try JSONDecoder().decode(MobileHelperPairingResponse.self, from: data), "\(capabilities)")
        }
        var extra = object
        extra["extra"] = true
        XCTAssertThrowsError(try JSONDecoder().decode(MobileHelperPairingResponse.self,
            from: JSONSerialization.data(withJSONObject: extra)))
    }

    func testPairingPayloadWireFormatStaysByteIdentical() throws {
        let value = payload
        let url = try value.pairingURL()
        XCTAssertEqual(url.scheme, "langtools-example-auth")
        XCTAssertEqual(url.host, "helper")
        XCTAssertEqual(url.path, "/pair")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.count, 6)
        XCTAssertEqual(Set(items.map(\.name)), ["v", "endpoint", "identity", "fingerprint", "code", "name"])
        XCTAssertEqual(value.version, 1)
        XCTAssertEqual(try MobileHelperPairingPayload.parse(url), value)
    }
}
