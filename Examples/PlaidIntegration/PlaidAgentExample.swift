//
//  PlaidAgentExample.swift
//  PlaidIntegration
//
//  Created by Claude on 1/10/26.
//
//  This file demonstrates how to use the PlaidAgent with the LangTools framework.
//

import Foundation
import LangTools
import Agents

// Uncomment the provider you want to use:
// import Anthropic
// import OpenAI

// MARK: - Example: Basic Usage (No UI)

/// Example demonstrating basic PlaidAgent usage without UI.
/// Useful for testing, CLI applications, or server-side usage.
func exampleBasicUsage() async throws {
    // 1. Create the Plaid service
    let plaidService = PlaidService(
        clientId: "your-client-id",
        secret: "your-secret",
        environment: .sandbox
    )

    // 2. Simulate a connected account for demo purposes
    // In production, this would happen through Plaid Link
    plaidService.setAccessToken("demo-access-token")

    // 3. Create the agent (without UI link handler)
    let plaidAgent = PlaidAgent(plaidService: plaidService)

    // 4. Set up your LLM provider
    // Uncomment and configure based on your provider:
    //
    // let anthropic = Anthropic(apiKey: "your-api-key")
    // let context = AgentContext(
    //     langTool: anthropic,
    //     model: Anthropic.Model.claude35Sonnet_latest,
    //     messages: [anthropic.userMessage("What are my account balances?")],
    //     eventHandler: { event in
    //         print(event.description)
    //     }
    // )
    //
    // let response = try await plaidAgent.execute(context: context)
    // print("Response: \(response)")

    print("PlaidAgent created successfully!")
    print("Agent: \(plaidAgent.name)")
    print("Description: \(plaidAgent.description)")
    print("Delegate agents: \(plaidAgent.delegateAgents.map { $0.name })")
}

// MARK: - Example: iOS App with Plaid Link

#if canImport(UIKit)
import UIKit

/// Example view controller demonstrating PlaidAgent integration in an iOS app.
class PlaidExampleViewController: UIViewController {

    // MARK: - Properties

    private let plaidService = PlaidService()
    private var plaidAgent: PlaidAgent!

    // MARK: - UI Components

    private lazy var chatTextView: UITextView = {
        let textView = UITextView()
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.backgroundColor = .secondarySystemBackground
        textView.layer.cornerRadius = 8
        textView.translatesAutoresizingMaskIntoConstraints = false
        return textView
    }()

    private lazy var inputTextField: UITextField = {
        let textField = UITextField()
        textField.placeholder = "Ask about your finances..."
        textField.borderStyle = .roundedRect
        textField.returnKeyType = .send
        textField.delegate = self
        textField.translatesAutoresizingMaskIntoConstraints = false
        return textField
    }()

    private lazy var sendButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("Send", for: .normal)
        button.addTarget(self, action: #selector(sendMessage), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private lazy var connectButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("Connect Bank Account", for: .normal)
        button.backgroundColor = .systemBlue
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 8
        button.addTarget(self, action: #selector(connectBankAccount), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupAgent()
        appendMessage("Assistant", "Hello! I'm your financial assistant. I can help you connect your bank account, view balances, analyze transactions, and provide financial insights.\n\nTo get started, tap 'Connect Bank Account' or ask me a question!")
    }

    // MARK: - Setup

    private func setupUI() {
        title = "Financial Assistant"
        view.backgroundColor = .systemBackground

        view.addSubview(connectButton)
        view.addSubview(chatTextView)
        view.addSubview(inputTextField)
        view.addSubview(sendButton)

        NSLayoutConstraint.activate([
            connectButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            connectButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            connectButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            connectButton.heightAnchor.constraint(equalToConstant: 44),

            chatTextView.topAnchor.constraint(equalTo: connectButton.bottomAnchor, constant: 16),
            chatTextView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            chatTextView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            inputTextField.topAnchor.constraint(equalTo: chatTextView.bottomAnchor, constant: 16),
            inputTextField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            inputTextField.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -16),

            sendButton.leadingAnchor.constraint(equalTo: inputTextField.trailingAnchor, constant: 8),
            sendButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            sendButton.centerYAnchor.constraint(equalTo: inputTextField.centerYAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 60)
        ])
    }

    private func setupAgent() {
        // Create the Plaid Link coordinator
        let linkCoordinator = PlaidLinkCoordinator(
            plaidService: plaidService,
            presentingViewController: self
        )

        // Create the agent with the link handler
        plaidAgent = PlaidAgent(
            plaidService: plaidService,
            onInitiateLink: { [linkCoordinator] in
                try await linkCoordinator.presentPlaidLink()
            }
        )
    }

    // MARK: - Actions

    @objc private func connectBankAccount() {
        Task {
            appendMessage("System", "Initiating bank connection...")

            do {
                let result = try await presentPlaidLink(plaidService: plaidService)
                appendMessage("System", result)
                updateConnectButton()
            } catch {
                appendMessage("Error", error.localizedDescription)
            }
        }
    }

    @objc private func sendMessage() {
        guard let message = inputTextField.text, !message.isEmpty else { return }

        inputTextField.text = ""
        appendMessage("You", message)

        Task {
            await processMessage(message)
        }
    }

    private func processMessage(_ message: String) async {
        appendMessage("Assistant", "Thinking...")

        // ============================================================
        // PRODUCTION IMPLEMENTATION:
        // Configure your LLM provider and execute the agent:
        //
        // let anthropic = Anthropic(apiKey: "your-api-key")
        // let context = AgentContext(
        //     langTool: anthropic,
        //     model: Anthropic.Model.claude35Sonnet_latest,
        //     messages: [anthropic.userMessage(message)],
        //     eventHandler: { [weak self] event in
        //         DispatchQueue.main.async {
        //             self?.handleAgentEvent(event)
        //         }
        //     }
        // )
        //
        // do {
        //     let response = try await plaidAgent.execute(context: context)
        //     await MainActor.run {
        //         removeLastMessage() // Remove "Thinking..."
        //         appendMessage("Assistant", response)
        //     }
        // } catch {
        //     await MainActor.run {
        //         removeLastMessage()
        //         appendMessage("Error", error.localizedDescription)
        //     }
        // }
        // ============================================================

        // Placeholder response for demo
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        await MainActor.run {
            removeLastMessage() // Remove "Thinking..."

            if plaidService.isAuthenticated {
                appendMessage("Assistant", "I received your message: \"\(message)\"\n\nTo see this working, configure your LLM provider (e.g., Anthropic, OpenAI) in the processMessage() method.")
            } else {
                appendMessage("Assistant", "Please connect your bank account first by tapping 'Connect Bank Account' above. Once connected, I can help you with:\n\n• Viewing account balances\n• Analyzing transactions\n• Spending insights\n• Saving recommendations")
            }
        }
    }

    private func handleAgentEvent(_ event: AgentEvent) {
        // Log agent events for debugging
        print(event.description)
    }

    // MARK: - UI Helpers

    private func appendMessage(_ sender: String, _ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        let formattedMessage = "[\(timestamp)] \(sender):\n\(message)\n\n"
        chatTextView.text += formattedMessage
        scrollToBottom()
    }

    private func removeLastMessage() {
        // Simple implementation - in production use a proper message model
        if let range = chatTextView.text.range(of: "Thinking...\n\n", options: .backwards) {
            let startIndex = chatTextView.text.index(range.lowerBound, offsetBy: -20, limitedBy: chatTextView.text.startIndex) ?? range.lowerBound
            chatTextView.text.removeSubrange(startIndex..<range.upperBound)
        }
    }

    private func scrollToBottom() {
        let bottom = NSRange(location: chatTextView.text.count, length: 0)
        chatTextView.scrollRangeToVisible(bottom)
    }

    private func updateConnectButton() {
        if plaidService.isAuthenticated {
            connectButton.setTitle("Bank Connected ✓", for: .normal)
            connectButton.backgroundColor = .systemGreen
        } else {
            connectButton.setTitle("Connect Bank Account", for: .normal)
            connectButton.backgroundColor = .systemBlue
        }
    }
}

// MARK: - UITextFieldDelegate

extension PlaidExampleViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        sendMessage()
        return true
    }
}

#endif // canImport(UIKit)

// MARK: - Example: Using Individual Agents

/// Example demonstrating how to use individual Plaid agents directly.
func exampleIndividualAgents() async throws {
    let plaidService = PlaidService()
    plaidService.setAccessToken("demo-token")

    // Use the accounts agent directly
    let accountsAgent = PlaidAccountsAgent(plaidService: plaidService)
    print("Accounts Agent: \(accountsAgent.name)")
    print("Tools: \(accountsAgent.tools?.map { $0.name } ?? [])")

    // Use the transactions agent directly
    let transactionsAgent = PlaidTransactionsAgent(plaidService: plaidService)
    print("Transactions Agent: \(transactionsAgent.name)")
    print("Tools: \(transactionsAgent.tools?.map { $0.name } ?? [])")

    // Use the insights agent directly
    let insightsAgent = PlaidInsightsAgent(plaidService: plaidService)
    print("Insights Agent: \(insightsAgent.name)")
    print("Tools: \(insightsAgent.tools?.map { $0.name } ?? [])")
}

// MARK: - Example: Testing Tools Directly

/// Example demonstrating how to test Plaid tools without an LLM.
func exampleTestTools() async throws {
    let plaidService = PlaidService()
    plaidService.setAccessToken("demo-token")

    print("Testing PlaidService directly:\n")

    // Test get accounts
    print("=== Accounts ===")
    let accounts = try await plaidService.getAccounts()
    print(accounts)

    // Test get balances
    print("\n=== Balances ===")
    let balances = try await plaidService.getBalances()
    print(balances)

    // Test get transactions
    print("\n=== Transactions ===")
    let transactions = try await plaidService.getTransactions(
        startDate: "2025-01-01",
        endDate: "2025-01-10"
    )
    print(transactions)

    // Test spending analysis
    print("\n=== Spending Analysis ===")
    let spending = try await plaidService.analyzeSpending(
        startDate: "2025-01-01",
        endDate: "2025-01-10"
    )
    print(spending)

    // Test financial summary
    print("\n=== Financial Summary ===")
    let summary = try await plaidService.getFinancialSummary(timePeriod: "month")
    print(summary)

    // Test recommendations
    print("\n=== Spending Recommendations ===")
    let recommendations = try await plaidService.getSpendingRecommendations()
    print(recommendations)

    // Test saving opportunities
    print("\n=== Saving Opportunities ===")
    let savings = try await plaidService.getSavingOpportunities()
    print(savings)
}

// MARK: - Main Entry Point

/// Run examples from command line.
@main
struct PlaidExamples {
    static func main() async {
        print("Plaid Agent Integration Examples\n")
        print("================================\n")

        do {
            print("1. Basic Usage Example")
            print("-----------------------")
            try await exampleBasicUsage()

            print("\n2. Individual Agents Example")
            print("-----------------------------")
            try await exampleIndividualAgents()

            print("\n3. Testing Tools Directly")
            print("--------------------------")
            try await exampleTestTools()

            print("\n================================")
            print("All examples completed successfully!")

        } catch {
            print("Error: \(error.localizedDescription)")
        }
    }
}
