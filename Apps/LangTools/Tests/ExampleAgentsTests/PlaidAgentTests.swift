//
//  PlaidAgentTests.swift
//  ExampleAgentsTests
//

import Agents
import Anthropic
import LangTools
import XCTest
@testable import ExampleAgents

final class PlaidAgentTests: XCTestCase {
    func testDelegatesToEachSpecialistAgent() {
        let agent = PlaidAgent()

        XCTAssertEqual(
            agent.delegateAgents.map { $0.name },
            ["plaidAuthAgent", "plaidAccountsAgent", "plaidTransactionsAgent", "plaidInsightsAgent"]
        )
        XCTAssertNil(agent.tools)
    }

    func testLinkToolIsOnlyOfferedWithALinkHandler() {
        let withoutLink = PlaidAgent()
        let withLink = PlaidAgent(onInitiateLink: { "connected" })

        XCTAssertNil(tool(named: "initiate_plaid_link", in: withoutLink))
        XCTAssertNotNil(tool(named: "initiate_plaid_link", in: withLink))
    }

    func testDataToolsRequireAConnectedAccount() async throws {
        let agent = PlaidAgent(plaidService: PlaidService())

        do {
            _ = try await call("get_accounts", in: agent)
            XCTFail("Expected get_accounts to fail without a connected account")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Not authenticated"))
        }
    }

    func testConnectionStatusAndDisconnectTrackTheService() async throws {
        let service = PlaidService()
        await service.setAccessToken("access-sandbox-test")
        let agent = PlaidAgent(plaidService: service)

        let connected = try await call("check_connection_status", in: agent)
        XCTAssertEqual(connected, "A bank account is connected.")

        _ = try await call("disconnect_account", in: agent)
        let isAuthenticated = await service.isAuthenticated
        XCTAssertFalse(isAuthenticated)
    }

    func testConnectedAccountDataIsLabeledAsSandboxData() async throws {
        let service = PlaidService()
        await service.setAccessToken("access-sandbox-test")
        let agent = PlaidAgent(plaidService: service)

        let result = try await call("get_accounts", in: agent)
        let accounts = try XCTUnwrap(result)
        XCTAssertTrue(accounts.hasPrefix("[Plaid sandbox demo data"))
        XCTAssertTrue(accounts.contains("checking-123"))
    }

    func testTransactionToolsRejectDatesOutsideYYYYMMDD() async throws {
        let service = PlaidService()
        await service.setAccessToken("access-sandbox-test")
        let agent = PlaidAgent(plaidService: service)

        do {
            _ = try await call("get_transactions", in: agent, args: [
                "start_date": .string("01/01/2025"),
                "end_date": .string("2025-01-31"),
            ])
            XCTFail("Expected get_transactions to reject a non-ISO date")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("YYYY-MM-DD"))
        }

        let result = try await call("get_transactions", in: agent, args: [
            "start_date": .string("2025-01-01"),
            "end_date": .string("2025-01-31"),
        ])
        let transactions = try XCTUnwrap(result)
        XCTAssertTrue(transactions.contains("Transactions from 2025-01-01 to 2025-01-31"))
    }

    func testFinancialSummaryRejectsUnknownTimePeriods() async throws {
        let service = PlaidService()
        await service.setAccessToken("access-sandbox-test")
        let agent = PlaidAgent(plaidService: service)

        do {
            _ = try await call("get_financial_summary", in: agent, args: ["time_period": .string("decade")])
            XCTFail("Expected get_financial_summary to reject an unknown period")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("time_period"))
        }
    }

    // MARK: - Helpers

    private func tool(named name: String, in agent: PlaidAgent) -> (any LangToolsTool)? {
        agent.delegateAgents.lazy.compactMap { $0.tools?.first { $0.name == name } }.first
    }

    private func call(_ name: String, in agent: PlaidAgent, args: [String: JSON] = [:]) async throws -> String? {
        let found = try XCTUnwrap(tool(named: name, in: agent), "Missing tool \(name)")
        let info = LangToolsRequestInfo(
            langTool: Anthropic(apiKey: "test"),
            model: Anthropic.Model.claude46Sonnet,
            messages: []
        )
        return try await found.callback?(info, args)
    }
}
