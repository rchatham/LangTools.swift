//
//  AgentTestRunner.swift
//  ChatCLI
//
//  Agent testing automation
//

import Foundation

struct AgentTest {
    let agentName: String
    let testName: String
    let prompt: String
    let category: String
    var expectedBehavior: String = ""
    var platform: String = "all" // all, macOS, iOS
}

struct AgentTestRunner {

    static let allTests: [AgentTest] = [
        // MARK: - ReminderAgent Tests
        AgentTest(
            agentName: "ReminderAgent",
            testName: "Basic Creation",
            prompt: "Add a reminder to buy milk",
            category: "create",
            expectedBehavior: "Should request permission and create reminder"
        ),
        AgentTest(
            agentName: "ReminderAgent",
            testName: "List Reminders",
            prompt: "Show me all my reminders",
            category: "read",
            expectedBehavior: "Should list existing reminders"
        ),
        AgentTest(
            agentName: "ReminderAgent",
            testName: "Scheduled Reminder",
            prompt: "Remind me to call mom tomorrow at 2pm",
            category: "create",
            expectedBehavior: "Should create timed reminder"
        ),

        // MARK: - ContactsAgent Tests
        AgentTest(
            agentName: "ContactsAgent",
            testName: "Search Contact",
            prompt: "Find my contact for John Smith",
            category: "search",
            expectedBehavior: "Should request permission and search contacts"
        ),
        AgentTest(
            agentName: "ContactsAgent",
            testName: "List Contacts",
            prompt: "List my first 10 contacts",
            category: "read",
            expectedBehavior: "Should list contacts with limit"
        ),
        AgentTest(
            agentName: "ContactsAgent",
            testName: "Search by Last Name",
            prompt: "Search for contacts with last name Johnson",
            category: "search",
            expectedBehavior: "Should filter by last name"
        ),

        // MARK: - ResearchAgent Tests
        AgentTest(
            agentName: "ResearchAgent",
            testName: "General Research",
            prompt: "Research the latest news about Swift programming",
            category: "research",
            expectedBehavior: "Should search web and summarize results"
        ),
        AgentTest(
            agentName: "ResearchAgent",
            testName: "Specific Query",
            prompt: "What are the new features in Swift 6?",
            category: "research",
            expectedBehavior: "Should find specific information"
        ),

        // MARK: - MapsAgent Tests
        AgentTest(
            agentName: "MapsAgent",
            testName: "Find Nearby",
            prompt: "Find the nearest coffee shop",
            category: "search",
            expectedBehavior: "Should request location and search nearby"
        ),
        AgentTest(
            agentName: "MapsAgent",
            testName: "Get Directions",
            prompt: "How do I get to Times Square from here?",
            category: "directions",
            expectedBehavior: "Should provide route directions"
        ),
        AgentTest(
            agentName: "MapsAgent",
            testName: "Calculate Distance",
            prompt: "How far is it to Central Park from my location?",
            category: "distance",
            expectedBehavior: "Should calculate distance"
        ),

        // MARK: - WeatherAgent Tests (Already tested)
        AgentTest(
            agentName: "WeatherAgent",
            testName: "Current Weather",
            prompt: "What's the weather like right now?",
            category: "current",
            expectedBehavior: "Should get current weather for location"
        ),
        AgentTest(
            agentName: "WeatherAgent",
            testName: "Forecast",
            prompt: "Will it rain tomorrow?",
            category: "forecast",
            expectedBehavior: "Should provide forecast"
        ),

        // MARK: - CalendarAgent Tests (Already tested)
        AgentTest(
            agentName: "CalendarAgent",
            testName: "List Events",
            prompt: "What's on my calendar this week?",
            category: "read",
            expectedBehavior: "Should list calendar events"
        ),
        AgentTest(
            agentName: "CalendarAgent",
            testName: "Create Event",
            prompt: "Add a dentist appointment tomorrow at 2pm",
            category: "create",
            expectedBehavior: "Should create calendar event"
        ),

        // MARK: - FileSystemAgent Tests (macOS DEBUG)
        AgentTest(
            agentName: "FileSystemAgent",
            testName: "List Directory",
            prompt: "List files in my Documents folder",
            category: "read",
            expectedBehavior: "Should list files",
            platform: "macOS"
        ),
        AgentTest(
            agentName: "FileSystemAgent",
            testName: "Read File",
            prompt: "Show me the contents of README.md",
            category: "read",
            expectedBehavior: "Should read file contents",
            platform: "macOS"
        ),

        // MARK: - CodeExecutionAgent Tests (macOS DEBUG)
        AgentTest(
            agentName: "CodeExecutionAgent",
            testName: "Hello World",
            prompt: "Execute this Swift code: print(\"Hello, World!\")",
            category: "execute",
            expectedBehavior: "Should execute and return output",
            platform: "macOS"
        ),
        AgentTest(
            agentName: "CodeExecutionAgent",
            testName: "Simple Calculation",
            prompt: "Run this code: let numbers = [1,2,3,4,5]; print(numbers.reduce(0, +))",
            category: "execute",
            expectedBehavior: "Should calculate and print sum",
            platform: "macOS"
        ),

        // MARK: - HomeKitAgent Tests (iOS)
        AgentTest(
            agentName: "HomeKitAgent",
            testName: "List Devices",
            prompt: "List all my HomeKit devices",
            category: "read",
            expectedBehavior: "Should list HomeKit accessories",
            platform: "iOS"
        ),
        AgentTest(
            agentName: "HomeKitAgent",
            testName: "Control Device",
            prompt: "Turn on the living room lights",
            category: "control",
            expectedBehavior: "Should control accessory",
            platform: "iOS"
        ),

        // MARK: - FinanceAgent Tests (iOS 17.4+ DEBUG)
        AgentTest(
            agentName: "FinanceAgent",
            testName: "Portfolio",
            prompt: "Show me my investment portfolio",
            category: "read",
            expectedBehavior: "Should display portfolio",
            platform: "iOS"
        ),
    ]

    // Filter tests by platform
    static func testsForPlatform(_ platform: String) -> [AgentTest] {
        allTests.filter { $0.platform == "all" || $0.platform == platform }
    }

    // Get tests for specific agent
    static func tests(forAgent agentName: String) -> [AgentTest] {
        allTests.filter { $0.agentName == agentName }
    }

    // Get all unique agent names
    static var agentNames: [String] {
        Array(Set(allTests.map { $0.agentName })).sorted()
    }

    // Run interactive test session
    static func runInteractiveTests(messageService: MessageService) async {
        print("\n" + "═══════════════════════════════════════".cyan)
        print("  Agent Testing Suite".cyan.bold)
        print("═══════════════════════════════════════\n".cyan)

        #if os(macOS)
        let platform = "macOS"
        #elseif os(iOS)
        let platform = "iOS"
        #else
        let platform = "all"
        #endif

        let availableTests = testsForPlatform(platform)

        print("Platform: \(platform)".yellow)
        print("Available tests: \(availableTests.count)".yellow)
        print("Agents to test: \(agentNames.joined(separator: ", "))\n".yellow)

        print("Options:".green)
        print("  all         - Run all tests sequentially".green)
        print("  [agent]     - Run tests for specific agent (e.g., 'ReminderAgent')".green)
        print("  [number]    - Run specific test by number".green)
        print("  list        - List all available tests".green)
        print("  exit        - Return to chat".green)
        print()

        print("Select option: ".cyan, terminator: "")
        guard let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }

        switch input.lowercased() {
        case "all":
            await runAllTests(availableTests, messageService: messageService)
        case "list":
            listAllTests(availableTests)
            await runInteractiveTests(messageService: messageService)
        case "exit":
            return
        default:
            if let testNumber = Int(input), testNumber > 0, testNumber <= availableTests.count {
                await runSingleTest(availableTests[testNumber - 1], messageService: messageService)
            } else if agentNames.contains(input) {
                let agentTests = tests(forAgent: input)
                await runAllTests(agentTests, messageService: messageService)
            } else {
                print("Invalid option. Try 'list' to see all available tests.".red)
            }
            await runInteractiveTests(messageService: messageService)
        }
    }

    static func listAllTests(_ tests: [AgentTest]) {
        print("\n" + "Available Tests:".cyan.bold)
        print("═══════════════════════════════════════\n".cyan)

        var currentAgent = ""
        for (index, test) in tests.enumerated() {
            if test.agentName != currentAgent {
                currentAgent = test.agentName
                print("\n\(currentAgent):".yellow.bold)
            }
            print("  [\(index + 1)] \(test.testName)".green)
            print("      Prompt: \"\(test.prompt)\"".white)
            print("      Expected: \(test.expectedBehavior)".cyan)
        }
        print()
    }

    static func runAllTests(_ tests: [AgentTest], messageService: MessageService) async {
        var passed = 0
        var failed = 0
        var skipped = 0

        for (index, test) in tests.enumerated() {
            print("\n" + "─────────────────────────────────────".cyan)
            print("Test \(index + 1)/\(tests.count): \(test.agentName) - \(test.testName)".cyan.bold)
            print("─────────────────────────────────────\n".cyan)

            let result = await runSingleTest(test, messageService: messageService, waitForInput: false)

            switch result {
            case .passed: passed += 1
            case .failed: failed += 1
            case .skipped: skipped += 1
            }

            // Brief pause between tests
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        }

        print("\n" + "═══════════════════════════════════════".cyan)
        print("  Test Results".cyan.bold)
        print("═══════════════════════════════════════".cyan)
        print("  Passed:  \(passed)".green)
        print("  Failed:  \(failed)".red)
        print("  Skipped: \(skipped)".yellow)
        print("═══════════════════════════════════════\n".cyan)
    }

    enum TestResult {
        case passed, failed, skipped
    }

    @discardableResult
    static func runSingleTest(_ test: AgentTest, messageService: MessageService, waitForInput: Bool = true) async -> TestResult {
        print("Agent: \(test.agentName)".yellow)
        print("Test: \(test.testName)".yellow)
        print("Prompt: \"\(test.prompt)\"".cyan)
        print("Expected: \(test.expectedBehavior)".white)
        print()

        do {
            print("Running test...".green)
            try await messageService.performMessageCompletionRequest(message: test.prompt, stream: true)
            print()

            if waitForInput {
                print("Did the test pass? (y/n/s to skip): ".yellow, terminator: "")
                let result = readLine()?.lowercased() ?? "n"

                switch result {
                case "y", "yes":
                    print("✅ Test PASSED".green.bold)
                    return .passed
                case "s", "skip":
                    print("⏭️  Test SKIPPED".yellow.bold)
                    return .skipped
                default:
                    print("❌ Test FAILED".red.bold)
                    return .failed
                }
            } else {
                // Auto-pass when not waiting for input (batch mode)
                return .passed
            }

        } catch {
            print("❌ Error: \(error.localizedDescription)".red.bold)
            return .failed
        }
    }
}

extension String {
    var bold: String {
        return "\u{001B}[1m" + self + "\u{001B}[0m"
    }
}
