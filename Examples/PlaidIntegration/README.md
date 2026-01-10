# Plaid Agent Integration

A financial assistant agent for the LangTools.swift framework that integrates with Plaid to provide banking data access and financial insights.

## Overview

This integration provides a hierarchical agent structure for interacting with Plaid's financial services:

- **PlaidAgent** - Main coordinator that delegates to specialized agents
- **PlaidAuthAgent** - Handles bank account connections via Plaid Link
- **PlaidAccountsAgent** - Retrieves account information and balances
- **PlaidTransactionsAgent** - Fetches and analyzes transaction data
- **PlaidInsightsAgent** - Provides financial insights and recommendations

## Requirements

- iOS 16.0+ / macOS 14.0+
- Swift 5.9+
- LangTools.swift framework
- Plaid developer account (for production use)
- Plaid Link iOS SDK (for iOS UI integration)

## Installation

### 1. Add LangTools.swift

```swift
dependencies: [
    .package(url: "https://github.com/rchatham/langtools.swift.git", from: "0.2.0")
]
```

### 2. Add Plaid Link SDK (for iOS apps)

```swift
dependencies: [
    .package(url: "https://github.com/plaid/plaid-link-ios.git", from: "5.0.0")
]
```

### 3. Copy the PlaidIntegration files to your project

## Usage

### Basic Setup

```swift
import LangTools
import Agents
import Anthropic // or OpenAI, etc.

// Create the Plaid service
let plaidService = PlaidService()

// Create the agent
let plaidAgent = PlaidAgent(plaidService: plaidService)

// Set up your LLM provider
let anthropic = Anthropic(apiKey: "your-api-key")

// Create context and execute
let context = AgentContext(
    langTool: anthropic,
    model: .claude35Sonnet_latest,
    messages: [anthropic.userMessage("What are my account balances?")],
    eventHandler: { event in
        print(event.description)
    }
)

let response = try await plaidAgent.execute(context: context)
```

### iOS App with Plaid Link

```swift
import UIKit

class ViewController: UIViewController {
    let plaidService = PlaidService()
    var plaidAgent: PlaidAgent!

    override func viewDidLoad() {
        super.viewDidLoad()

        // Create coordinator for Plaid Link UI
        let coordinator = PlaidLinkCoordinator(
            plaidService: plaidService,
            presentingViewController: self
        )

        // Create agent with link handler
        plaidAgent = PlaidAgent(
            plaidService: plaidService,
            onInitiateLink: {
                try await coordinator.presentPlaidLink()
            }
        )
    }
}
```

### Using Individual Agents

```swift
// Use specific agents directly for focused tasks
let accountsAgent = PlaidAccountsAgent(plaidService: plaidService)
let transactionsAgent = PlaidTransactionsAgent(plaidService: plaidService)
let insightsAgent = PlaidInsightsAgent(plaidService: plaidService)
```

## Agent Capabilities

### PlaidAuthAgent Tools
- `check_connection_status` - Check if a bank is connected
- `disconnect_account` - Disconnect the current bank
- `initiate_plaid_link` - Start the connection flow (when UI handler provided)

### PlaidAccountsAgent Tools
- `get_accounts` - List all connected accounts
- `get_balances` - Get current balances

### PlaidTransactionsAgent Tools
- `get_transactions` - Fetch transactions for a date range
- `analyze_spending` - Analyze spending patterns by category

### PlaidInsightsAgent Tools
- `get_financial_summary` - Get comprehensive financial overview
- `get_spending_recommendations` - Get personalized spending advice
- `get_saving_opportunities` - Identify ways to save money

## Configuration

### Environment Variables

```bash
export PLAID_CLIENT_ID="your-client-id"
export PLAID_SECRET="your-secret"
```

### Programmatic Configuration

```swift
let plaidService = PlaidService(
    clientId: "your-client-id",
    secret: "your-secret",
    environment: .sandbox  // or .development, .production
)
```

## Production Considerations

1. **Backend Required**: In production, you should proxy Plaid API calls through your backend to keep credentials secure.

2. **Token Storage**: Store access tokens securely using Keychain.

3. **Error Handling**: Implement proper error handling for network failures and API errors.

4. **Webhook Support**: Consider implementing Plaid webhooks for real-time transaction updates.

## Mock Implementation

The current `PlaidService` implementation returns simulated data for development and testing. To connect to the real Plaid API:

1. Set up a backend server that communicates with Plaid's API
2. Update `PlaidService` methods to make requests to your backend
3. Implement proper token exchange and storage

## License

This example is part of LangTools.swift and follows the same license.
