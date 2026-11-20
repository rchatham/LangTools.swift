//
//  VoiceCommandTests.swift
//  CLITests
//

import XCTest
@testable import CLI

final class VoiceCommandTests: XCTestCase {
    private var savedVoiceEnabled = false

    override func setUp() {
        super.setUp()
        savedVoiceEnabled = UserDefaults.voiceEnabled
        UserDefaults.voiceEnabled = false
    }

    override func tearDown() {
        UserDefaults.voiceEnabled = savedVoiceEnabled
        super.tearDown()
    }

    func testVoiceIsARecognizedCommand() {
        XCTAssertEqual(CommandParser.commandType(for: "voice"), .voice)
        XCTAssertEqual(CommandType.voice.usage, "/voice [on|off|status]")
    }

    func testVoiceIsInteractiveOnly() {
        let command = SlashCommand(name: "voice", arguments: [], rawArguments: "")
        XCTAssertFalse(CLI.isCommandSupportedInNonInteractiveMode(command, type: .voice))
    }

    func testBareVoiceToggles() {
        XCTAssertTrue(VoiceCommand.apply(argument: "").hasPrefix("Voice output is on"))
        XCTAssertTrue(UserDefaults.voiceEnabled)
        XCTAssertEqual(VoiceCommand.apply(argument: ""), "Voice output is off.")
        XCTAssertFalse(UserDefaults.voiceEnabled)
    }

    func testExplicitOnOffAndStatus() {
        _ = VoiceCommand.apply(argument: "ON")
        XCTAssertTrue(UserDefaults.voiceEnabled)
        _ = VoiceCommand.apply(argument: "on")
        XCTAssertTrue(UserDefaults.voiceEnabled, "on should not toggle")
        XCTAssertTrue(VoiceCommand.apply(argument: "status").hasPrefix("Voice output is on"))
        _ = VoiceCommand.apply(argument: " off ")
        XCTAssertFalse(UserDefaults.voiceEnabled)
    }

    func testUnknownArgumentShowsUsageAndLeavesSettingAlone() {
        XCTAssertEqual(VoiceCommand.apply(argument: "loud"), "Usage: /voice [on|off|status]")
        XCTAssertFalse(UserDefaults.voiceEnabled)
    }

    func testSpeakableTextSkipsCodeBlocks() {
        let reply = """
        Here is the fix:
        ```swift
        let x = 1
        ```
        That should do it.
        """
        XCTAssertEqual(SpeechService.speakableText(from: reply), "Here is the fix:\nThat should do it.")
    }

    func testSpeakableTextIsTrimmedToTTSLimit() {
        let long = String(repeating: "a", count: SpeechService.maxInputLength + 100)
        XCTAssertEqual(SpeechService.speakableText(from: long).count, SpeechService.maxInputLength)
        XCTAssertEqual(SpeechService.speakableText(from: "  \n```\ncode\n```\n "), "")
    }
}
