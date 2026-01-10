//
//  PlaidService.swift
//  PlaidIntegration
//
//  Created by Claude on 1/10/26.
//

import Foundation

// MARK: - Plaid Service

/// Service layer for Plaid API interactions.
/// This is a mock implementation that simulates Plaid API responses.
/// In production, this would make actual API calls to your backend
/// which proxies requests to Plaid's API.
public class PlaidService {

    // MARK: - Properties

    private var accessToken: String?
    private let clientId: String
    private let secret: String
    private let environment: PlaidEnvironment

    // MARK: - Initialization

    public init(
        clientId: String = "",
        secret: String = "",
        environment: PlaidEnvironment = .sandbox
    ) {
        self.clientId = clientId.isEmpty
            ? ProcessInfo.processInfo.environment["PLAID_CLIENT_ID"] ?? ""
            : clientId
        self.secret = secret.isEmpty
            ? ProcessInfo.processInfo.environment["PLAID_SECRET"] ?? ""
            : secret
        self.environment = environment
    }

    // MARK: - Authentication State

    public var isAuthenticated: Bool {
        accessToken != nil
    }

    public func setAccessToken(_ token: String) {
        self.accessToken = token
    }

    public func clearAccessToken() {
        self.accessToken = nil
    }

    // MARK: - Link Token

    /// Request a link token from your backend.
    /// In production, this would make a request to your server,
    /// which then requests a link token from Plaid's API.
    public func createLinkToken() async throws -> String {
        // Simulated network delay
        try await Task.sleep(nanoseconds: 500_000_000)

        // In production: POST to your backend -> Plaid API
        return "link-sandbox-" + UUID().uuidString
    }

    /// Exchange a public token for an access token.
    /// In production, this would be done server-side for security.
    public func exchangePublicToken(_ publicToken: String) async throws -> String {
        // Simulated network delay
        try await Task.sleep(nanoseconds: 500_000_000)

        // Store the access token
        self.accessToken = "access-sandbox-" + UUID().uuidString

        return "Successfully connected to your financial institution. Your accounts are now accessible."
    }

    // MARK: - Accounts

    /// Get all connected accounts.
    public func getAccounts() async throws -> String {
        guard accessToken != nil else {
            throw PlaidServiceError.notAuthenticated
        }

        try await Task.sleep(nanoseconds: 300_000_000)

        return """
        Connected Accounts:

        1. Checking Account
           ID: checking-123
           Balance: $2,450.33
           Type: Depository - Checking
           Institution: Chase Bank

        2. Savings Account
           ID: savings-456
           Balance: $15,678.91
           Type: Depository - Savings
           Institution: Chase Bank

        3. Credit Card
           ID: cc-789
           Balance: -$432.19
           Type: Credit - Credit Card
           Institution: American Express
        """
    }

    /// Get balances for specified accounts.
    public func getBalances(accountIds: [String]? = nil) async throws -> String {
        guard accessToken != nil else {
            throw PlaidServiceError.notAuthenticated
        }

        try await Task.sleep(nanoseconds: 300_000_000)

        if let accountIds = accountIds, !accountIds.isEmpty {
            let accountList = accountIds.joined(separator: ", ")
            return """
            Current Balances for Selected Accounts (\(accountList)):

            Checking Account (checking-123): $2,450.33
            Available: $2,400.33 (pending transactions: $50.00)
            """
        } else {
            return """
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
    }

    // MARK: - Transactions

    /// Get transactions for a specified date range.
    public func getTransactions(
        startDate: String,
        endDate: String,
        accountIds: [String]? = nil,
        count: Int? = nil,
        offset: Int? = nil
    ) async throws -> String {
        guard accessToken != nil else {
            throw PlaidServiceError.notAuthenticated
        }

        try await Task.sleep(nanoseconds: 400_000_000)

        let accountFilter = accountIds?.isEmpty == false
            ? " for accounts: \(accountIds!.joined(separator: ", "))"
            : ""
        let pagination = count != nil ? " (showing \(count!) transactions)" : ""

        return """
        Transactions from \(startDate) to \(endDate)\(accountFilter)\(pagination):

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

        Date: 2025-01-07
        Description: RESTAURANT - DINNER
        Amount: -$42.12
        Category: Food and Drink > Restaurants
        Account: Credit Card (cc-789)

        Date: 2025-01-05
        Description: PAYROLL DEPOSIT
        Amount: +$2,450.00
        Category: Income > Payroll
        Account: Checking (checking-123)

        Date: 2025-01-03
        Description: ELECTRIC UTILITY
        Amount: -$89.32
        Category: Service > Utilities
        Account: Checking (checking-123)

        Total: 6 transactions
        """
    }

    /// Analyze spending patterns for a date range.
    public func analyzeSpending(
        startDate: String,
        endDate: String,
        accountIds: [String]? = nil
    ) async throws -> String {
        guard accessToken != nil else {
            throw PlaidServiceError.notAuthenticated
        }

        try await Task.sleep(nanoseconds: 500_000_000)

        return """
        Spending Analysis from \(startDate) to \(endDate):

        Total Spending: $1,248.32
        Total Income: $2,450.00
        Net Cash Flow: +$1,201.68

        Spending by Category:
        ├── Food and Drink: $420.15 (33.7%)
        │   ├── Groceries: $285.00
        │   └── Restaurants: $135.15
        ├── Housing: $375.00 (30.0%)
        │   └── Rent/Mortgage: $375.00
        ├── Transportation: $180.32 (14.4%)
        │   ├── Gas: $105.32
        │   └── Public Transit: $75.00
        ├── Healthcare: $87.40 (7.0%)
        │   └── Pharmacies: $87.40
        ├── Entertainment: $98.45 (7.9%)
        │   └── Streaming Services: $45.38
        └── Utilities: $87.00 (7.0%)

        Top Merchants:
        1. GROCERY MART: $210.45
        2. LANDLORD PAYMENTS: $375.00
        3. SHELL GAS STATION: $105.32
        4. NETFLIX/SPOTIFY: $45.38
        5. CVS PHARMACY: $87.40

        Month-over-Month Change: -5.2% (spending decreased)
        """
    }

    // MARK: - Insights

    /// Get financial summary for a specific time period.
    public func getFinancialSummary(timePeriod: String) async throws -> String {
        guard accessToken != nil else {
            throw PlaidServiceError.notAuthenticated
        }

        try await Task.sleep(nanoseconds: 400_000_000)

        return """
        Financial Summary - Past \(timePeriod.capitalized):

        ═══════════════════════════════════════
        CASH FLOW
        ───────────────────────────────────────
        Total Income:     $3,750.00
        Total Expenses:   $2,845.67
        Net Cash Flow:    +$904.33
        Savings Rate:     24.1%

        ═══════════════════════════════════════
        ACCOUNT BALANCES
        ───────────────────────────────────────
        Checking:         $2,450.33
        Savings:          $15,678.91
        Credit Card Debt: $432.19
        Net Worth:        $17,697.05

        ═══════════════════════════════════════
        KEY INSIGHTS
        ───────────────────────────────────────
        • Food spending is 15% higher than last \(timePeriod)
        • You have $123 in recurring subscriptions
        • Housing is your largest expense (35% of spending)
        • 3 ATM fees totaling $12.00 this \(timePeriod)
        • Credit utilization: 8.6% (Excellent)

        ═══════════════════════════════════════
        FINANCIAL HEALTH SCORE: 72/100 (Good)
        ───────────────────────────────────────
        """
    }

    /// Get personalized spending recommendations.
    public func getSpendingRecommendations() async throws -> String {
        guard accessToken != nil else {
            throw PlaidServiceError.notAuthenticated
        }

        try await Task.sleep(nanoseconds: 400_000_000)

        return """
        Personalized Spending Recommendations:

        🍽️ FOOD & DINING
        Your restaurant spending has increased 20% this month.
        Consider meal planning to reduce grocery costs.
        Potential monthly savings: $50-75

        📺 SUBSCRIPTIONS
        You have 5 active subscriptions totaling $64.99/month:
        • Netflix: $15.99
        • Spotify: $10.99
        • HBO Max: $15.99
        • Gym: $12.00
        • Cloud Storage: $9.99
        Review if you're actively using all services.

        🏧 ATM FEES
        You've paid $12 in ATM fees this month.
        Use in-network ATMs or get cash back at grocery stores.
        Annual savings potential: $144

        ⚡ UTILITIES
        Your utility bills are 15% higher than average.
        Consider energy-saving measures or check for water leaks.

        🚗 TRANSPORTATION
        Gas spending is higher than similar households.
        Consider carpooling 1-2 days per week.
        Potential monthly savings: $40-60
        """
    }

    /// Get saving opportunities based on spending patterns.
    public func getSavingOpportunities() async throws -> String {
        guard accessToken != nil else {
            throw PlaidServiceError.notAuthenticated
        }

        try await Task.sleep(nanoseconds: 400_000_000)

        return """
        Saving Opportunities Identified:

        ═══════════════════════════════════════
        1. HIGH-YIELD SAVINGS ACCOUNT
        ───────────────────────────────────────
        Current APY: 0.01%
        Recommended APY: 4.50%+
        Based on your $15,678.91 balance:
        Additional annual earnings: ~$705

        ═══════════════════════════════════════
        2. SUBSCRIPTION OPTIMIZATION
        ───────────────────────────────────────
        Identified unused/underused subscriptions:
        • Gym membership (visited 2x this month)
        • Cloud storage (using 12% of capacity)
        Potential annual savings: $264

        ═══════════════════════════════════════
        3. CREDIT CARD REWARDS OPTIMIZATION
        ───────────────────────────────────────
        Current card: No rewards
        Based on your spending patterns:
        • 2% cash back on groceries: ~$68/year
        • 3% on dining: ~$49/year
        • 1.5% on everything else: ~$68/year
        Total potential rewards: ~$185/year

        ═══════════════════════════════════════
        4. BANK FEE AVOIDANCE
        ───────────────────────────────────────
        Paid in last 3 months: $45
        Set up low balance alerts to avoid overdraft
        Use fee-free ATM network
        Annual savings: ~$180

        ═══════════════════════════════════════
        5. AUTOMATIC SAVINGS
        ───────────────────────────────────────
        Suggested: $100/week automatic transfer
        Build emergency fund: $5,200 in one year
        Compound growth (at 4.5%): ~$5,435

        ═══════════════════════════════════════
        TOTAL ESTIMATED ANNUAL SAVINGS: $1,334+
        ═══════════════════════════════════════
        """
    }
}

// MARK: - Supporting Types

public enum PlaidEnvironment: String {
    case sandbox
    case development
    case production
}

public enum PlaidServiceError: Error, LocalizedError {
    case notAuthenticated
    case invalidParameters(String)
    case networkError(String)
    case serverError(String)
    case linkError(String)
    case unknownError

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not authenticated. Please connect your bank account first using Plaid Link."
        case .invalidParameters(let message):
            return "Invalid parameters: \(message)"
        case .networkError(let message):
            return "Network error: \(message)"
        case .serverError(let message):
            return "Server error: \(message)"
        case .linkError(let message):
            return "Plaid Link error: \(message)"
        case .unknownError:
            return "An unknown error occurred."
        }
    }
}
