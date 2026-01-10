//
//  PlaidAgents.swift
//  PlaidIntegration
//
//  Created by Claude on 1/10/26.
//

import Foundation
import LangTools
import Agents

// MARK: - Plaid Authentication Agent

/// Agent responsible for handling Plaid Link authentication flow.
/// Manages bank account connections and access token lifecycle.
public struct PlaidAuthAgent: Agent {

    private let plaidService: PlaidService
    private let onInitiateLink: (() async throws -> String)?

    public init(
        plaidService: PlaidService = PlaidService(),
        onInitiateLink: (() async throws -> String)? = nil
    ) {
        self.plaidService = plaidService
        self.onInitiateLink = onInitiateLink
    }

    public let name = "plaidAuthAgent"
    public let description = "Agent responsible for connecting bank accounts through Plaid Link"
    public let instructions = """
        You are responsible for helping users connect their bank accounts through Plaid Link.
        Guide them through the authentication process and manage the connection lifecycle.

        When helping users:
        1. Explain what Plaid Link is and what data will be accessed
        2. Respect privacy concerns and be transparent about data usage
        3. Help troubleshoot connection issues if they arise
        4. Confirm successful connections

        Be clear and concise about what will happen when they connect their accounts.
        If Plaid Link is not available (no UI handler configured), inform the user
        that they need to use the app's UI to connect their bank account.
        """

    public var delegateAgents: [any Agent] = []

    public var tools: [any LangToolsTool]? {
        var toolsList: [Tool] = [
            Tool(
                name: "check_connection_status",
                description: "Check if a bank account is currently connected",
                tool_schema: .init(),
                callback: { [plaidService] _ in
                    if plaidService.isAuthenticated {
                        return "A bank account is currently connected. You can access account data, transactions, and insights."
                    } else {
                        return "No bank account is currently connected. The user needs to connect their bank through Plaid Link first."
                    }
                }
            ),
            Tool(
                name: "disconnect_account",
                description: "Disconnect the currently connected bank account",
                tool_schema: .init(),
                callback: { [plaidService] _ in
                    plaidService.clearAccessToken()
                    return "Bank account has been disconnected successfully. Connect a new account to access financial data."
                }
            )
        ]

        // Only add initiate_plaid_link if a handler is provided
        if let linkHandler = onInitiateLink {
            toolsList.append(
                Tool(
                    name: "initiate_plaid_link",
                    description: "Start the Plaid Link flow to connect a bank account. This will open the Plaid Link UI.",
                    tool_schema: .init(),
                    callback: { _ in
                        do {
                            return try await linkHandler()
                        } catch {
                            throw AgentError("Failed to connect account: \(error.localizedDescription)")
                        }
                    }
                )
            )
        }

        return toolsList
    }
}

// MARK: - Plaid Accounts Agent

/// Agent responsible for fetching and displaying account information.
public struct PlaidAccountsAgent: Agent {

    private let plaidService: PlaidService

    public init(plaidService: PlaidService = PlaidService()) {
        self.plaidService = plaidService
    }

    public let name = "plaidAccountsAgent"
    public let description = "Agent responsible for fetching financial account information and balances"
    public let instructions = """
        You are responsible for retrieving account information via Plaid.
        This includes account details, types, and current balances.

        When presenting account information:
        1. Format currency values consistently with dollar signs and two decimal places
        2. Clearly distinguish between different account types (checking, savings, credit)
        3. Explain the difference between current and available balances when relevant
        4. Be mindful of privacy when discussing specific amounts

        If the user is not connected to a bank, inform them they need to connect first.
        """

    public var delegateAgents: [any Agent] = []

    public var tools: [any LangToolsTool]? {
        [
            Tool(
                name: "get_accounts",
                description: "Get a list of all connected financial accounts with their details",
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
                            description: "Comma-separated list of account IDs to get balances for. Leave empty for all accounts."
                        )
                    ],
                    required: []
                ),
                callback: { [plaidService] args in
                    let accountIds = args["account_ids"]?.stringValue?
                        .split(separator: ",")
                        .map { String($0).trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }

                    do {
                        return try await plaidService.getBalances(accountIds: accountIds)
                    } catch {
                        throw AgentError(error.localizedDescription)
                    }
                }
            )
        ]
    }
}

// MARK: - Plaid Transactions Agent

/// Agent responsible for fetching and analyzing transaction data.
public struct PlaidTransactionsAgent: Agent {

    private let plaidService: PlaidService

    public init(plaidService: PlaidService = PlaidService()) {
        self.plaidService = plaidService
    }

    public let name = "plaidTransactionsAgent"
    public let description = "Agent responsible for fetching and analyzing financial transactions"
    public let instructions = """
        You are responsible for retrieving and analyzing transaction data via Plaid.
        Help users understand their spending patterns and transaction history.

        When working with transactions:
        1. Use ISO 8601 date format (YYYY-MM-DD) for all date parameters
        2. Format currency amounts consistently
        3. Group transactions logically when presenting summaries
        4. Be sensitive when discussing financial transactions - don't be judgmental
        5. Highlight unusual or notable transactions when relevant

        Common date ranges users might ask for:
        - "Last week": 7 days back from today
        - "Last month": 30 days back from today
        - "This month": First day of current month to today

        If the user is not connected to a bank, inform them they need to connect first.
        """

    public var delegateAgents: [any Agent] = []

    public var tools: [any LangToolsTool]? {
        [
            Tool(
                name: "get_transactions",
                description: "Get transactions for a specific date range",
                tool_schema: .init(
                    properties: [
                        "start_date": .init(
                            type: "string",
                            description: "Start date in YYYY-MM-DD format (e.g., 2025-01-01)"
                        ),
                        "end_date": .init(
                            type: "string",
                            description: "End date in YYYY-MM-DD format (e.g., 2025-01-31)"
                        ),
                        "account_ids": .init(
                            type: "string",
                            description: "Comma-separated list of account IDs (optional, defaults to all accounts)"
                        ),
                        "count": .init(
                            type: "integer",
                            description: "Maximum number of transactions to return (optional)"
                        ),
                        "offset": .init(
                            type: "integer",
                            description: "Number of transactions to skip for pagination (optional)"
                        )
                    ],
                    required: ["start_date", "end_date"]
                ),
                callback: { [plaidService] args in
                    guard let startDate = args["start_date"]?.stringValue,
                          let endDate = args["end_date"]?.stringValue else {
                        throw AgentError("Missing required date parameters. Please provide start_date and end_date in YYYY-MM-DD format.")
                    }

                    // Validate date format
                    let dateFormatter = ISO8601DateFormatter()
                    dateFormatter.formatOptions = [.withFullDate]
                    guard dateFormatter.date(from: startDate) != nil,
                          dateFormatter.date(from: endDate) != nil else {
                        throw AgentError("Invalid date format. Please use YYYY-MM-DD format (e.g., 2025-01-15).")
                    }

                    let accountIds = args["account_ids"]?.stringValue?
                        .split(separator: ",")
                        .map { String($0).trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    let count = args["count"]?.intValue
                    let offset = args["offset"]?.intValue

                    do {
                        return try await plaidService.getTransactions(
                            startDate: startDate,
                            endDate: endDate,
                            accountIds: accountIds,
                            count: count,
                            offset: offset
                        )
                    } catch {
                        throw AgentError(error.localizedDescription)
                    }
                }
            ),
            Tool(
                name: "analyze_spending",
                description: "Analyze spending patterns across categories for a date range",
                tool_schema: .init(
                    properties: [
                        "start_date": .init(
                            type: "string",
                            description: "Start date in YYYY-MM-DD format"
                        ),
                        "end_date": .init(
                            type: "string",
                            description: "End date in YYYY-MM-DD format"
                        ),
                        "account_ids": .init(
                            type: "string",
                            description: "Comma-separated list of account IDs (optional)"
                        )
                    ],
                    required: ["start_date", "end_date"]
                ),
                callback: { [plaidService] args in
                    guard let startDate = args["start_date"]?.stringValue,
                          let endDate = args["end_date"]?.stringValue else {
                        throw AgentError("Missing required date parameters.")
                    }

                    let accountIds = args["account_ids"]?.stringValue?
                        .split(separator: ",")
                        .map { String($0).trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }

                    do {
                        return try await plaidService.analyzeSpending(
                            startDate: startDate,
                            endDate: endDate,
                            accountIds: accountIds
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

/// Agent responsible for providing financial insights and recommendations.
public struct PlaidInsightsAgent: Agent {

    private let plaidService: PlaidService

    public init(plaidService: PlaidService = PlaidService()) {
        self.plaidService = plaidService
    }

    public let name = "plaidInsightsAgent"
    public let description = "Agent responsible for providing financial insights, recommendations, and saving opportunities"
    public let instructions = """
        You are responsible for analyzing financial data and providing actionable insights.
        Use transaction and account data to help users improve their financial health.

        When providing insights:
        1. Be respectful and avoid judgmental statements about spending habits
        2. Focus on actionable advice that can realistically improve their situation
        3. Prioritize recommendations by potential impact
        4. Acknowledge good financial behaviors, not just areas for improvement
        5. Consider the user's apparent priorities based on their spending

        Types of insights you can provide:
        - Financial health summaries
        - Spending pattern analysis
        - Saving opportunities
        - Budget recommendations

        Always frame advice positively and constructively.
        If the user is not connected to a bank, inform them they need to connect first.
        """

    public var delegateAgents: [any Agent] = []

    public var tools: [any LangToolsTool]? {
        [
            Tool(
                name: "get_financial_summary",
                description: "Get a comprehensive financial health summary for a time period",
                tool_schema: .init(
                    properties: [
                        "time_period": .init(
                            type: "string",
                            enumValues: ["week", "month", "quarter", "year"],
                            description: "Time period for the financial summary"
                        )
                    ],
                    required: ["time_period"]
                ),
                callback: { [plaidService] args in
                    guard let timePeriod = args["time_period"]?.stringValue else {
                        throw AgentError("Missing time period. Please specify: week, month, quarter, or year.")
                    }

                    let validPeriods = ["week", "month", "quarter", "year"]
                    guard validPeriods.contains(timePeriod.lowercased()) else {
                        throw AgentError("Invalid time period '\(timePeriod)'. Please use: week, month, quarter, or year.")
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

/// Main coordinator agent for Plaid financial services.
/// Delegates to specialized sub-agents for specific tasks.
public struct PlaidAgent: Agent {

    public init(
        plaidService: PlaidService = PlaidService(),
        onInitiateLink: (() async throws -> String)? = nil
    ) {
        self.delegateAgents = [
            PlaidAuthAgent(plaidService: plaidService, onInitiateLink: onInitiateLink),
            PlaidAccountsAgent(plaidService: plaidService),
            PlaidTransactionsAgent(plaidService: plaidService),
            PlaidInsightsAgent(plaidService: plaidService)
        ]
    }

    public let name = "plaidAgent"
    public let description = """
        Financial assistant that connects to bank accounts through Plaid. \
        Can help with connecting accounts, viewing balances, analyzing transactions, \
        and providing personalized financial insights and recommendations.
        """
    public let instructions = """
        You are a financial assistant that helps users manage their finances through Plaid integration.
        You can connect to their bank accounts, retrieve financial data, and provide insights.

        Your capabilities through delegate agents:
        1. plaidAuthAgent - Connect and manage bank account connections
        2. plaidAccountsAgent - View account details and balances
        3. plaidTransactionsAgent - Fetch and analyze transactions
        4. plaidInsightsAgent - Get financial insights and recommendations

        When helping users:
        1. First check if they have a connected bank account
        2. Guide them to connect if needed before accessing financial data
        3. Use the most appropriate delegate agent for their request
        4. Provide clear explanations of financial concepts
        5. Be sensitive when discussing financial difficulties
        6. Suggest actionable steps to improve financial health

        Important guidelines:
        - Never make judgmental comments about spending habits
        - Always prioritize security and privacy in financial matters
        - Be transparent about what data is being accessed
        - If something goes wrong, explain clearly and suggest next steps
        """

    public var delegateAgents: [any Agent]

    // Main agent delegates to sub-agents, no direct tools
    public var tools: [any LangToolsTool]? = nil
}
