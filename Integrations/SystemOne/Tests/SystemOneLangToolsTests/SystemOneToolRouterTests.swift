import Foundation
import LangTools
import SystemOne
import SystemOneChat
import SystemOneD1
import XCTest
@testable import SystemOneLangTools

final class SystemOneToolRouterTests: XCTestCase {
    private let options = [
        ToolRoutingOption(name: "calendarAgent", description: "Written for a language model"),
        ToolRoutingOption(name: "researchAgent", description: "Written for a language model"),
    ]

    func testAsksOneQuestionWithTheCatchAllLast() async throws {
        let decider = RecordingDecider()
        let router = SystemOneToolRouter(decider: decider)

        _ = try await router.route(message: "What's on Friday?", options: options)

        let keys = await decider.lastOptions.map(\.key)
        XCTAssertEqual(keys, ["calendarAgent", "researchAgent", "generate_text"])
        let instructions = await decider.lastInstructions
        XCTAssertEqual(instructions, ChatAgent.routingInstructions)
    }

    func testRoutingDescriptionsReplaceToolDescriptions() async throws {
        let decider = RecordingDecider()
        let router = SystemOneToolRouter(
            decider: decider,
            routingDescriptions: ["calendarAgent": "Their calendar, events, or schedule"]
        )

        _ = try await router.route(message: "What's on Friday?", options: options)

        let descriptions = await decider.lastOptions.map(\.description)
        XCTAssertEqual(descriptions[0], "Their calendar, events, or schedule")
        XCTAssertEqual(descriptions[1], "Written for a language model")
    }

    func testScoresEveryToolAndOmitsTheCatchAll() async throws {
        let decider = RecordingDecider(probabilities: [
            ("calendarAgent", 0.1), ("researchAgent", 0.7), ("generate_text", 0.2),
        ])
        let router = SystemOneToolRouter(decider: decider)

        let decision = try await router.route(message: "Look this up", options: options)

        XCTAssertEqual(decision.toolProbabilities.keys.sorted(), ["calendarAgent", "researchAgent"])
        XCTAssertEqual(try XCTUnwrap(decision.toolProbabilities["researchAgent"]), 0.7, accuracy: 0.0001)
    }

    /// Runs real d1 over labeled messages. Set `D1_MODEL_FOLDER` to run it.
    ///
    /// "Hidden" counts messages whose tool fell below the cutoff, and "stray" counts
    /// no-tool messages that still received a tool the model might wrongly call.
    func testD1RoutesTheAppAgents() async throws {
        guard let folder = ProcessInfo.processInfo.environment["D1_MODEL_FOLDER"], !folder.isEmpty else {
            throw XCTSkip("Set D1_MODEL_FOLDER to run the d1 routing probe.")
        }
        let router = try await SystemOneToolRouter.d1(
            modelFolder: URL(fileURLWithPath: folder, isDirectory: true),
            routingDescriptions: AppAgentRoutingProbe.descriptions
        )
        func score(_ cases: [(message: String, tool: String?)]) async throws -> [(message: String, tool: String?, scores: [String: Double])] {
            var scored: [(message: String, tool: String?, scores: [String: Double])] = []
            for probe in cases {
                let decision = try await router.route(message: probe.message, options: AppAgentRoutingProbe.options)
                scored.append((probe.message, probe.tool, decision.toolProbabilities))
            }
            return scored
        }
        func report(_ name: String, _ scored: [(message: String, tool: String?, scores: [String: Double])], cutoff: Double, listing: Bool) -> (hidden: Int, stray: Int) {
            var hidden = 0, stray = 0, kept = 0
            for item in scored {
                let plausible = item.scores.filter { $0.value >= cutoff }.keys.sorted()
                kept += plausible.count
                let miss: Bool
                if let tool = item.tool {
                    miss = !plausible.contains(tool)
                    if miss { hidden += 1 }
                } else {
                    miss = !plausible.isEmpty
                    if miss { stray += 1 }
                }
                if listing, miss {
                    print("probe \(name) MISS expected \(item.tool ?? "no tool") kept \(plausible) <- \(item.message)")
                }
            }
            print("probe \(name) cutoff \(cutoff): hidden \(hidden), stray \(stray), of \(scored.count); tools sent per message \(String(format: "%.2f", Double(kept) / Double(scored.count)))")
            return (hidden, stray)
        }

        let known = try await score(AppAgentRoutingProbe.cases + AppAgentRoutingProbe.heldOutCases + AppAgentRoutingProbe.shortCases)
        for cutoff in [0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5] {
            _ = report("sweep", known, cutoff: cutoff, listing: false)
        }
        _ = report("known", known, cutoff: AppAgentRoutingProbe.minimumProbability, listing: true)

        let fresh = report(
            "fresh",
            try await score(AppAgentRoutingProbe.freshCases),
            cutoff: AppAgentRoutingProbe.minimumProbability,
            listing: true
        )
        XCTAssertLessThanOrEqual(fresh.hidden + fresh.stray, AppAgentRoutingProbe.freshCases.count / 4)
    }
}

/// Labeled messages for the agents the LangTools app registers.
enum AppAgentRoutingProbe {
    static let descriptions = [
        "calendarAgent": "Their calendar, events, meetings, or schedule",
        "reminderAgent": "To be reminded of something, or their to-do lists, shopping lists, or tasks",
        "researchAgent": "To look something up on the web or research a topic",
        "current_date_time": "The current date, day, or time",
        "calculate": "To calculate a number or do math",
    ]

    /// Every tool the app registers, in the order it offers them.
    static let options = ["calendarAgent", "reminderAgent", "researchAgent", "current_date_time", "calculate"].map {
        ToolRoutingOption(name: $0, description: "An agent")
    }

    static let cases: [(message: String, tool: String?)] = [
        ("What's on my calendar tomorrow?", "calendarAgent"),
        ("Schedule a meeting with Sam on Friday at 2pm", "calendarAgent"),
        ("Am I free Thursday afternoon?", "calendarAgent"),
        ("Move my dentist appointment to next week", "calendarAgent"),
        ("Remind me to call mom tonight", "reminderAgent"),
        ("Add milk to my shopping list", "reminderAgent"),
        ("What's on my to-do list?", "reminderAgent"),
        ("Mark the laundry task as done", "reminderAgent"),
        ("Research the latest advances in solid-state batteries", "researchAgent"),
        ("Search the web for the best hiking boots this year", "researchAgent"),
        ("What's the latest news on the Mars mission?", "researchAgent"),
        ("Find articles about sourdough starters", "researchAgent"),
        ("Hi! How are you today?", nil),
        ("Thanks, that was helpful", nil),
        ("Write me a short poem about the sea", nil),
        ("What is the capital of France?", nil),
        ("Explain recursion like I'm five", nil),
        ("Rewrite this sentence to sound friendlier: send it now", nil),
        ("What time is it?", "current_date_time"),
        ("What's today's date?", "current_date_time"),
        ("What is 15% of 80?", "calculate"),
        ("Multiply 37 by 12", "calculate"),
    ]

    /// Never used to tune the descriptions above, so they estimate new messages.
    static let heldOutCases: [(message: String, tool: String?)] = [
        ("Do I have anything booked next Monday?", "calendarAgent"),
        ("Cancel my 3pm with the design team", "calendarAgent"),
        ("Put a haircut on my schedule for Saturday morning", "calendarAgent"),
        ("Don't let me forget to pay rent on the first", "reminderAgent"),
        ("Create a list for the camping trip", "reminderAgent"),
        ("Which of my tasks are overdue?", "reminderAgent"),
        ("Look up reviews of the new Pixel phone", "researchAgent"),
        ("Who won the most recent Formula 1 race?", "researchAgent"),
        ("Summarize what's known about the new malaria vaccine", "researchAgent"),
        ("Good morning!", nil),
        ("Translate 'where is the station' into Spanish", nil),
        ("Give me three name ideas for a coffee shop", nil),
    ]

    /// Short messages give d1 little to go on. A user found "hi" reaching web search.
    static let shortCases: [(message: String, tool: String?)] = [
        ("hi", nil), ("hello", nil), ("hey", nil), ("Hi!", nil), ("thanks", nil), ("ok", nil),
        ("lol", nil), ("good night", nil), ("what's up", nil), ("who are you?", nil),
        ("help", nil), ("2+2", "calculate"), ("tell me a joke", nil),
        ("remind me", "reminderAgent"), ("calendar", "calendarAgent"), ("search", "researchAgent"),
    ]

    /// Run only after the cutoff is chosen, so they estimate new messages.
    static let freshCases: [(message: String, tool: String?)] = [
        ("What time is my flight meeting on Tuesday?", "calendarAgent"),
        ("Block off next Wednesday morning for deep work", "calendarAgent"),
        ("Add a team lunch to my calendar on the 14th", "calendarAgent"),
        ("Set a reminder to water the plants on Sunday", "reminderAgent"),
        ("Put eggs and butter on the grocery list", "reminderAgent"),
        ("Show me what's left on my packing list", "reminderAgent"),
        ("Find recent studies on intermittent fasting", "researchAgent"),
        ("What are people saying online about the new MacBook?", "researchAgent"),
        ("Look up how much a passport renewal costs", "researchAgent"),
        ("hey there", nil),
        ("good afternoon", nil),
        ("you're funny", nil),
        ("sorry, never mind", nil),
        ("Fix the grammar in: me and him goes home", nil),
        ("What's a good synonym for happy?", nil),
        ("Write a haiku about autumn", nil),
        ("what day of the week is it", "current_date_time"),
        ("Do you know the time in my timezone?", "current_date_time"),
        ("square root of 144", "calculate"),
        ("Split an $84 bill between 3 people", "calculate"),
    ]

    /// `ToolRoutingPolicy.defaultMinimumProbability` in the app's Chat module.
    static let minimumProbability = 0.2
}

private actor RecordingDecider: ActionDecider {
    private let probabilities: [(key: String, probability: Double)]
    private(set) var lastOptions: [ChoiceOption] = []
    private(set) var lastInstructions = ""

    init(probabilities: [(String, Double)] = [("calendarAgent", 0.9), ("researchAgent", 0.05), ("generate_text", 0.05)]) {
        self.probabilities = probabilities.map { (key: $0.0, probability: $0.1) }
    }

    func chooseAction(state: SystemOneState, options: [ChoiceOption], instructions: String) async throws -> ChoiceAnswer {
        lastOptions = options
        lastInstructions = instructions
        let best = probabilities.max { $0.probability < $1.probability }!
        return ChoiceAnswer(
            choice: best.key,
            probabilities: probabilities.map { ProbabilityEntry(key: $0.key, probability: $0.probability) },
            confidence: best.probability
        )
    }
}
