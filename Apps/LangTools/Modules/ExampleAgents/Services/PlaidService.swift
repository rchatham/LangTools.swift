//
//  PlaidService.swift
//  LangToolsApp
//

import Foundation

/// Mock Plaid service that returns canned sandbox data.
///
/// In production, every method here would call your own backend, which holds the
/// Plaid client id and secret and proxies requests to Plaid's API. Never ship
/// Plaid credentials in the app itself.
public actor PlaidService {
    private var accessToken: String?

    public init() {}

    public var isAuthenticated: Bool { accessToken != nil }

    public func setAccessToken(_ token: String) {
        accessToken = token
    }

    public func clearAccessToken() {
        accessToken = nil
    }

    // MARK: - Link

    /// Request a link token used to open Plaid Link.
    public func createLinkToken() async throws -> String {
        "link-sandbox-" + UUID().uuidString
    }

    /// Exchange the public token returned by Plaid Link for an access token.
    public func exchangePublicToken(_ publicToken: String) async throws -> String {
        accessToken = "access-sandbox-" + UUID().uuidString
        return "Successfully connected to your financial institution. Your accounts are now accessible."
    }

    // MARK: - Accounts

    public func getAccounts() async throws -> String {
        try requireAuthentication()
        return Self.sandboxNotice + """
            Connected Accounts:

            1. Checking Account
               ID: checking-123
               Balance: $2,450.33
               Type: Depository - Checking

            2. Savings Account
               ID: savings-456
               Balance: $15,678.91
               Type: Depository - Savings

            3. Credit Card
               ID: cc-789
               Balance: -$432.19
               Type: Credit - Credit Card
            """
    }

    public func getBalances(accountIds: [String]? = nil) async throws -> String {
        try requireAuthentication()
        if let accountIds, !accountIds.isEmpty {
            return Self.sandboxNotice + """
                Current Balances for Selected Accounts (\(accountIds.joined(separator: ", "))):

                Checking Account (checking-123): $2,450.33
                Available: $2,400.33 (pending transactions: $50.00)
                """
        }
        return Self.sandboxNotice + """
            Current Balances for All Accounts:

            Checking Account (checking-123): $2,450.33
            Available: $2,400.33 (pending transactions: $50.00)

            Savings Account (savings-456): $15,678.91
            Available: $15,678.91

            Credit Card (cc-789): -$432.19
            Credit Limit: $5,000.00
            Available Credit: $4,567.81
            """
    }

    // MARK: - Transactions

    public func getTransactions(
        startDate: String,
        endDate: String,
        accountIds: [String]? = nil,
        count: Int? = nil,
        offset: Int? = nil
    ) async throws -> String {
        try requireAuthentication()
        let accountFilter = accountIds.map { $0.isEmpty ? "" : " for accounts: \($0.joined(separator: ", "))" } ?? ""
        return Self.sandboxNotice + """
            Transactions from \(startDate) to \(endDate)\(accountFilter):

            Date: 2025-01-10
            Description: GROCERY MART
            Amount: -$65.49
            Category: Food and Drink > Groceries
            Account: Checking (checking-123)

            Date: 2025-01-09
            Description: MONTHLY TRANSIT PASS
            Amount: -$75.00
            Category: Travel > Public Transportation
            Account: Checking (checking-123)

            Date: 2025-01-08
            Description: PHARMACY
            Amount: -$23.47
            Category: Healthcare > Pharmacies
            Account: Credit Card (cc-789)

            Date: 2025-01-05
            Description: PAYROLL DEPOSIT
            Amount: +$2,450.00
            Category: Income > Payroll
            Account: Checking (checking-123)
            """
    }

    public func analyzeSpending(startDate: String, endDate: String, accountIds: [String]? = nil) async throws -> String {
        try requireAuthentication()
        return Self.sandboxNotice + """
            Spending Analysis from \(startDate) to \(endDate):

            Total Spending: $1,248.32
            Total Income: $2,450.00
            Net Cash Flow: +$1,201.68

            By Category:
            - Food and Drink: $420.15 (33.7%)
            - Housing: $375.00 (30.0%)
            - Transportation: $180.32 (14.4%)
            - Entertainment: $98.45 (7.9%)
            - Healthcare: $87.40 (7.0%)
            - Utilities: $87.00 (7.0%)

            Month-over-Month Change: -5.2%
            """
    }

    // MARK: - Insights

    public func getFinancialSummary(timePeriod: String) async throws -> String {
        try requireAuthentication()
        return Self.sandboxNotice + """
            Financial Summary for the past \(timePeriod):

            Total Income: $3,750.00
            Total Expenses: $2,845.67
            Net Cash Flow: +$904.33
            Savings Rate: 24.1%

            Notable Insights:
            - Food spending is 15% higher than the previous \(timePeriod)
            - $123 in recurring subscriptions
            - Housing is the largest expense category (35% of spending)
            - 3 ATM fees totaling $12.00
            """
    }

    public func getSpendingRecommendations() async throws -> String {
        try requireAuthentication()
        return Self.sandboxNotice + """
            Spending Recommendations:

            1. Food & Dining: restaurant spending rose 20% this month; meal planning could save $50-75/month.
            2. Subscriptions: 5 active subscriptions total $64.99/month; review the ones you rarely use.
            3. ATM Fees: $12 in fees this month; use in-network ATMs or cash back at checkout.
            4. Utilities: bills are 15% above average; check for leaks or energy-saving options.
            """
    }

    public func getSavingOpportunities() async throws -> String {
        try requireAuthentication()
        return Self.sandboxNotice + """
            Saving Opportunities:

            1. High-yield savings: moving the $15,678.91 savings balance from 0.01% APY could earn ~$700/year.
            2. Subscription audit: cancelling underused subscriptions could save ~$264/year.
            3. Card rewards: a card with grocery and dining rewards could earn ~$185/year at current spending.
            4. Fee avoidance: low-balance alerts could avoid ~$180/year in bank fees.
            """
    }

    // MARK: - Private

    /// Prefixed to every data response so the model can tell the user the numbers are not real.
    private static let sandboxNotice = "[Plaid sandbox demo data, not from a real institution]\n\n"

    private func requireAuthentication() throws {
        guard accessToken != nil else { throw PlaidServiceError.notAuthenticated }
    }
}

public enum PlaidServiceError: Error, LocalizedError {
    case notAuthenticated

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not authenticated. Please connect your bank account first using Plaid Link."
        }
    }
}
