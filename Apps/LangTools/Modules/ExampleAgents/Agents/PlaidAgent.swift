//
//  PlaidAgent.swift
//  LangToolsApp
//

import Foundation
import LangTools
import Agents

// MARK: - Plaid Auth Agent
struct PlaidAuthAgent: Agent {
    private let plaidService: PlaidService
    private let onInitiateLink: (() async throws -> String)?

    init(plaidService: PlaidService, onInitiateLink: (() async throws -> String)? = nil) {
        self.plaidService = plaidService
        self.onInitiateLink = onInitiateLink
    }

    let name = "plaidAuthAgent"
    let description = "Agent responsible for connecting bank accounts through Plaid Link"
    let instructions = """
        You are responsible for helping users connect their bank accounts through Plaid Link.
        Explain what data will be accessed before connecting and confirm when a connection succeeds.
        If the initiate_plaid_link tool is not available, tell the user to connect their bank
        account from the app's UI instead.
        """

    var delegateAgents: [any Agent] = []

    var tools: [any LangToolsTool]? {
        var tools = [
            Tool(
                name: "check_connection_status",
                description: "Check whether a bank account is currently connected",
                tool_schema: .init(),
                callback: { [plaidService] _ in
                    await plaidService.isAuthenticated
                        ? "A bank account is connected."
                        : "No bank account is connected. The user must connect one through Plaid Link first."
                }
            ),
            Tool(
                name: "disconnect_account",
                description: "Disconnect the currently connected bank account",
                tool_schema: .init(),
                callback: { [plaidService] _ in
                    await plaidService.clearAccessToken()
                    return "The bank account has been disconnected."
                }
            )
        ]
        if let onInitiateLink {
            tools.append(Tool(
                name: "initiate_plaid_link",
                description: "Open Plaid Link so the user can connect a bank account",
                tool_schema: .init(),
                callback: { _ in
                    do {
                        return try await onInitiateLink()
                    } catch {
                        throw AgentError("Failed to connect account: \(error.localizedDescription)")
                    }
                }
            ))
        }
        return tools
    }
}

// MARK: - Plaid Accounts Agent
struct PlaidAccountsAgent: Agent {
    private let plaidService: PlaidService

    init(plaidService: PlaidService) {
        self.plaidService = plaidService
    }

    let name = "plaidAccountsAgent"
    let description = "Agent responsible for fetching financial account details and balances"
    let instructions = """
        You are responsible for retrieving account information via Plaid, including account
        types and current balances. Format currency with a dollar sign and two decimal places,
        and explain the difference between current and available balances when relevant.
        """

    var delegateAgents: [any Agent] = []

    var tools: [any LangToolsTool]? {
        [
            Tool(
                name: "get_accounts",
                description: "Get the list of connected financial accounts",
                tool_schema: .init(),
                callback: { [plaidService] _ in
                    do {
                        return try await plaidService.getAccounts()
                    } catch {
                        throw AgentError(error.localizedDescription)
                    }
                }
            ),
            Tool(
                name: "get_balances",
                description: "Get current balances for connected financial accounts",
                tool_schema: .init(
                    properties: [
                        "account_ids": .init(
                            type: "string",
                            description: "Comma-separated list of account IDs (optional, defaults to all accounts)"
                        )
                    ],
                    required: []
                ),
                callback: { [plaidService] args in
                    do {
                        return try await plaidService.getBalances(accountIds: args["account_ids"]?.stringValue?.accountIds)
                    } catch {
                        throw AgentError(error.localizedDescription)
                    }
                }
            )
        ]
    }
}

// MARK: - Plaid Transactions Agent
struct PlaidTransactionsAgent: Agent {
    private let plaidService: PlaidService

    init(plaidService: PlaidService) {
        self.plaidService = plaidService
    }

    let name = "plaidTransactionsAgent"
    let description = "Agent responsible for fetching and analyzing financial transactions"
    let instructions = """
        You are responsible for retrieving and analyzing transaction data via Plaid.
        Always pass dates in YYYY-MM-DD format, resolving relative ranges such as
        "last month" against the current time. Never be judgmental about spending.
        """

    var delegateAgents: [any Agent] = []

    var tools: [any LangToolsTool]? {
        [
            Tool(
                name: "get_transactions",
                description: "Get transactions for a date range",
                tool_schema: .init(
                    properties: [
                        "start_date": .init(type: "string", description: "Start date in YYYY-MM-DD format"),
                        "end_date": .init(type: "string", description: "End date in YYYY-MM-DD format"),
                        "account_ids": .init(type: "string", description: "Comma-separated list of account IDs (optional)"),
                        "count": .init(type: "integer", description: "Maximum number of transactions to return (optional)"),
                        "offset": .init(type: "integer", description: "Number of transactions to skip (optional)")
                    ],
                    required: ["start_date", "end_date"]
                ),
                callback: { [plaidService] args in
                    guard let startDate = args["start_date"]?.stringValue, startDate.isPlaidDate,
                          let endDate = args["end_date"]?.stringValue, endDate.isPlaidDate
                    else {
                        throw AgentError("Invalid dates. Provide start_date and end_date in YYYY-MM-DD format.")
                    }
                    do {
                        return try await plaidService.getTransactions(
                            startDate: startDate,
                            endDate: endDate,
                            accountIds: args["account_ids"]?.stringValue?.accountIds,
                            count: args["count"]?.intValue,
                            offset: args["offset"]?.intValue
                        )
                    } catch {
                        throw AgentError(error.localizedDescription)
                    }
                }
            ),
            Tool(
                name: "analyze_spending",
                description: "Analyze spending by category for a date range",
                tool_schema: .init(
                    properties: [
                        "start_date": .init(type: "string", description: "Start date in YYYY-MM-DD format"),
                        "end_date": .init(type: "string", description: "End date in YYYY-MM-DD format"),
                        "account_ids": .init(type: "string", description: "Comma-separated list of account IDs (optional)")
                    ],
                    required: ["start_date", "end_date"]
                ),
                callback: { [plaidService] args in
                    guard let startDate = args["start_date"]?.stringValue, startDate.isPlaidDate,
                          let endDate = args["end_date"]?.stringValue, endDate.isPlaidDate
                    else {
                        throw AgentError("Invalid dates. Provide start_date and end_date in YYYY-MM-DD format.")
                    }
                    do {
                        return try await plaidService.analyzeSpending(
                            startDate: startDate,
                            endDate: endDate,
                            accountIds: args["account_ids"]?.stringValue?.accountIds
                        )
                    } catch {
                        throw AgentError(error.localizedDescription)
                    }
                }
            )
        ]
    }
}

// MARK: - Plaid Insights Agent
struct PlaidInsightsAgent: Agent {
    private let plaidService: PlaidService

    init(plaidService: PlaidService) {
        self.plaidService = plaidService
    }

    let name = "plaidInsightsAgent"
    let description = "Agent responsible for financial insights, spending recommendations, and saving opportunities"
    let instructions = """
        You are responsible for turning account and transaction data into actionable financial
        insights. Prioritize recommendations by impact, acknowledge good habits as well as areas
        to improve, and never make judgmental statements about spending.
        """

    var delegateAgents: [any Agent] = []

    var tools: [any LangToolsTool]? {
        [
            Tool(
                name: "get_financial_summary",
                description: "Get a financial health summary for a time period",
                tool_schema: .init(
                    properties: [
                        "time_period": .init(
                            type: "string",
                            enumValues: ["week", "month", "quarter", "year"],
                            description: "Time period for the summary"
                        )
                    ],
                    required: ["time_period"]
                ),
                callback: { [plaidService] args in
                    guard let timePeriod = args["time_period"]?.stringValue,
                          ["week", "month", "quarter", "year"].contains(timePeriod)
                    else {
                        throw AgentError("Invalid time_period. Use week, month, quarter, or year.")
                    }
                    do {
                        return try await plaidService.getFinancialSummary(timePeriod: timePeriod)
                    } catch {
                        throw AgentError(error.localizedDescription)
                    }
                }
            ),
            Tool(
                name: "get_spending_recommendations",
                description: "Get personalized recommendations to optimize spending",
                tool_schema: .init(),
                callback: { [plaidService] _ in
                    do {
                        return try await plaidService.getSpendingRecommendations()
                    } catch {
                        throw AgentError(error.localizedDescription)
                    }
                }
            ),
            Tool(
                name: "get_saving_opportunities",
                description: "Identify opportunities to save money based on spending patterns",
                tool_schema: .init(),
                callback: { [plaidService] _ in
                    do {
                        return try await plaidService.getSavingOpportunities()
                    } catch {
                        throw AgentError(error.localizedDescription)
                    }
                }
            )
        ]
    }
}

// MARK: - Main Plaid Agent
/// Financial assistant backed by Plaid.
///
/// `PlaidService` returns canned sandbox data. To connect real accounts, add the Plaid
/// Link SDK (https://github.com/plaid/plaid-link-ios) to the app, present Link from
/// `onInitiateLink`, and pass the resulting public token to
/// `PlaidService.exchangePublicToken(_:)`. Without `onInitiateLink`, the agent cannot
/// connect an account itself.
public struct PlaidAgent: Agent {
    public init(plaidService: PlaidService = PlaidService(), onInitiateLink: (() async throws -> String)? = nil) {
        delegateAgents = [
            PlaidAuthAgent(plaidService: plaidService, onInitiateLink: onInitiateLink),
            PlaidAccountsAgent(plaidService: plaidService),
            PlaidTransactionsAgent(plaidService: plaidService),
            PlaidInsightsAgent(plaidService: plaidService)
        ]
    }

    public let name = "plaidAgent"
    public let description = """
        Financial assistant that connects to bank accounts through Plaid. Can connect accounts, \
        show balances, analyze transactions, and give personalized financial insights.
        """
    public let instructions = """
        You are a financial assistant that helps users manage their finances through Plaid.
        Your responsibilities include:
        1. Connecting and managing bank accounts through the auth agent
        2. Showing account details and balances through the accounts agent
        3. Fetching and analyzing transactions through the transactions agent
        4. Providing insights and recommendations through the insights agent

        Check that a bank account is connected before requesting financial data.
        Tell the user when data is sandbox demo data. Never make judgmental comments about
        spending, and always prioritize security and privacy.
        """

    public var delegateAgents: [any Agent]

    // Main agent uses delegate agents' tools
    public var tools: [any LangToolsTool]? = nil
}

// MARK: - Helpers
private extension String {
    /// Splits a comma-separated list of account IDs, dropping blanks.
    var accountIds: [String] {
        split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Whether the string is a full date in YYYY-MM-DD format.
    var isPlaidDate: Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.date(from: self) != nil
    }
}
