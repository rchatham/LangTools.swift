//
//  ToolChainTests.swift
//  CLITests
//
//  Integration tests for tool execution chains
//

import XCTest
@testable import CLI

final class ToolChainTests: XCTestCase {

    var tempDirectory: URL!

    override func setUpWithError() throws {
        // Create a temporary directory for test files
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIToolChainTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Clean up temp directory
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    // MARK: - Tool Registry Integration Tests

    func testToolRegistryContainsAllExpectedTools() {
        let registry = ToolRegistry.shared
        // Core tools use PascalCase, advanced tools use snake_case
        let expectedTools = [
            "Read", "Write", "Edit", "Bash", "Glob", "Grep",
            "task", "todo_write", "web_fetch",
            "enter_plan_mode", "exit_plan_mode", "ask_user_question"
        ]

        for toolName in expectedTools {
            XCTAssertNotNil(registry.tool(named: toolName),
                           "Tool '\(toolName)' should be registered")
        }
    }

    func testToolRegistryGeneratesOpenAISchemas() {
        let registry = ToolRegistry.shared
        let tools = registry.asOpenAITools()

        XCTAssertGreaterThan(tools.count, 0, "Should have registered tools")
    }

    // MARK: - File Operation Chain Tests

    func testReadWriteEditChain() throws {
        let testFile = tempDirectory.appendingPathComponent("chain_test.txt")

        // Write initial content
        let initialContent = "Hello World"
        try FileSystemService.writeFile(at: testFile.path, content: initialContent)

        // Read and verify
        let readContent = try FileSystemService.readFile(at: testFile.path)
        XCTAssertTrue(readContent.contains("Hello World"))

        // Edit the file
        _ = try FileSystemService.editFile(
            at: testFile.path,
            oldString: "World",
            newString: "CLI"
        )

        // Verify edit
        let editedContent = try FileSystemService.readFile(at: testFile.path)
        XCTAssertTrue(editedContent.contains("Hello CLI"))
        XCTAssertFalse(editedContent.contains("World"))
    }

    func testGlobAndReadChain() throws {
        // Create a subdirectory with test files
        let subdir = tempDirectory.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)

        let files = ["test1.swift", "test2.swift", "test3.txt"]
        for file in files {
            let path = subdir.appendingPathComponent(file)
            try FileSystemService.writeFile(at: path.path, content: "Content of \(file)")
        }

        // Verify files were created
        for file in files {
            let path = subdir.appendingPathComponent(file).path
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), "File \(file) should exist")
        }

        // Glob for Swift files using ** pattern which matches recursively
        let matches = try FileSystemService.glob(
            pattern: "**/*.swift",
            in: tempDirectory.path
        )

        // Should find 2 Swift files
        XCTAssertEqual(matches.count, 2, "Should find 2 Swift files")

        // Read each matched file
        for match in matches {
            let content = try FileSystemService.readFile(at: match)
            XCTAssertTrue(content.contains("Content of test"))
        }
    }

    func testGrepResults() throws {
        // Create test files with specific content
        let files = [
            ("search1.txt", "This file contains the SEARCH_TERM here"),
            ("search2.txt", "No special content"),
            ("search3.txt", "Another SEARCH_TERM occurrence")
        ]

        for (name, content) in files {
            let path = tempDirectory.appendingPathComponent(name)
            try FileSystemService.writeFile(at: path.path, content: content)
        }

        // Grep for pattern
        let matches = try FileSystemService.grep(
            pattern: "SEARCH_TERM",
            in: tempDirectory.path
        )

        XCTAssertEqual(matches.count, 2, "Should find 2 files with SEARCH_TERM")
        XCTAssertTrue(matches.contains { $0.file.contains("search1.txt") })
        XCTAssertTrue(matches.contains { $0.file.contains("search3.txt") })
    }

    // MARK: - Process Execution Chain Tests

    func testBashCommandChain() async throws {
        // Create a file via bash
        let createFile = tempDirectory.appendingPathComponent("bash_created.txt")
        let createResult = try await ProcessService.execute(
            command: "echo 'Created by bash' > '\(createFile.path)'"
        )
        XCTAssertEqual(createResult.exitCode, 0)

        // Read the file via bash
        let readResult = try await ProcessService.execute(
            command: "cat '\(createFile.path)'"
        )
        XCTAssertEqual(readResult.exitCode, 0)
        XCTAssertTrue(readResult.stdout.contains("Created by bash"))

        // Verify with FileSystemService
        let verified = try FileSystemService.readFile(at: createFile.path)
        XCTAssertTrue(verified.contains("Created by bash"))
    }

    func testBashWithWorkingDirectory() async throws {
        // Execute pwd in temp directory
        let result = try await ProcessService.execute(
            command: "pwd",
            workingDirectory: tempDirectory.path
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains(tempDirectory.lastPathComponent))
    }

    // MARK: - Tool Approval Policy Tests

    func testToolApprovalPolicyCategorizesTools() {
        // Write operations need approval
        XCTAssertTrue(ToolApprovalPolicy.requiresApproval(toolName: "write", parameters: [:]))
        XCTAssertTrue(ToolApprovalPolicy.requiresApproval(toolName: "edit", parameters: [:]))
        XCTAssertTrue(ToolApprovalPolicy.requiresApproval(toolName: "bash", parameters: [:]))

        // Read-only tools don't require approval by default
        XCTAssertFalse(ToolApprovalPolicy.requiresApproval(toolName: "read", parameters: [:]))
        XCTAssertFalse(ToolApprovalPolicy.requiresApproval(toolName: "glob", parameters: [:]))
        XCTAssertFalse(ToolApprovalPolicy.requiresApproval(toolName: "grep", parameters: [:]))
    }

    func testToolApprovalPolicyOperationDescriptions() {
        let writeDesc = ToolApprovalPolicy.operationDescription(
            toolName: "write",
            parameters: ["file_path": "/tmp/test.txt"]
        )
        XCTAssertTrue(writeDesc.contains("Write to file"))
        XCTAssertTrue(writeDesc.contains("/tmp/test.txt"))

        let bashDesc = ToolApprovalPolicy.operationDescription(
            toolName: "bash",
            parameters: ["command": "ls -la"]
        )
        XCTAssertTrue(bashDesc.contains("Execute command"))
        XCTAssertTrue(bashDesc.contains("ls"))
    }

    // MARK: - Diff Generation Tests

    func testDiffGeneratorBasicDiff() {
        let old = "Line 1\nLine 2\nLine 3"
        let new = "Line 1\nModified Line 2\nLine 3"

        let diff = DiffGenerator.diff(old: old, new: new)

        let removed = diff.filter { $0.type == .removed }
        let added = diff.filter { $0.type == .added }

        XCTAssertEqual(removed.count, 1)
        XCTAssertEqual(added.count, 1)
        XCTAssertTrue(removed.first?.content.contains("Line 2") ?? false)
        XCTAssertTrue(added.first?.content.contains("Modified") ?? false)
    }

    func testDiffGeneratorUnifiedFormat() {
        let old = "Hello\nWorld"
        let new = "Hello\nSwift"

        let unified = DiffGenerator.unifiedDiff(old: old, new: new)

        XCTAssertTrue(unified.contains("---"))
        XCTAssertTrue(unified.contains("+++"))
        XCTAssertTrue(unified.contains("-World"))
        XCTAssertTrue(unified.contains("+Swift"))
    }

    func testDiffGeneratorSideBySide() {
        let old = "Hello\nWorld"
        let new = "Hello\nSwift"

        let sideBySide = DiffGenerator.sideBySide(old: old, new: new, width: 20)

        XCTAssertTrue(sideBySide.contains("Old"))
        XCTAssertTrue(sideBySide.contains("New"))
        XCTAssertTrue(sideBySide.contains("Hello"))
    }

    // MARK: - Theme Manager Tests

    @MainActor
    func testThemeManagerColorSchemes() {
        let manager = ThemeManager.shared

        // Test all themes have valid color schemes
        for theme in ChatTheme.allCases {
            manager.currentTheme = theme
            XCTAssertNotNil(manager.colors.primary)
            XCTAssertNotNil(manager.colors.error)
            XCTAssertNotNil(manager.colors.success)
        }
    }

    @MainActor
    func testThemeManagerThemeSwitching() {
        let manager = ThemeManager.shared

        // Switch through themes
        XCTAssertTrue(manager.setTheme("monokai"))
        XCTAssertEqual(manager.currentTheme, .monokai)

        XCTAssertTrue(manager.setTheme("solarized"))
        XCTAssertEqual(manager.currentTheme, .solarized)

        // Invalid theme
        XCTAssertFalse(manager.setTheme("nonexistent"))
    }

    // MARK: - Progress Indicator Tests

    func testProgressBarPercentage() {
        let bar = ProgressBar()

        let zero = bar.render(percentage: 0)
        XCTAssertTrue(zero.contains("0"))

        let half = bar.render(percentage: 50)
        XCTAssertTrue(half.contains("50"))

        let full = bar.render(percentage: 100)
        XCTAssertTrue(full.contains("100"))
    }

    func testProgressBarFraction() {
        let bar = ProgressBar()

        let progress = bar.render(current: 5, total: 10)
        XCTAssertTrue(progress.contains("50"))
        XCTAssertTrue(progress.contains("5/10"))
    }

    // MARK: - Elapsed Time Formatter Tests

    func testElapsedTimeFormatterShortDurations() {
        // Sub-second durations show milliseconds
        let subSecond = ElapsedTimeFormatter.format(0.5)
        XCTAssertTrue(subSecond.contains("ms"))

        // Seconds
        let seconds = ElapsedTimeFormatter.format(30)
        XCTAssertTrue(seconds.contains("s"))
    }

    func testElapsedTimeFormatterMinutes() {
        let minute = ElapsedTimeFormatter.format(60)
        XCTAssertTrue(minute.contains("m"))

        let minutes = ElapsedTimeFormatter.format(90)
        XCTAssertTrue(minutes.contains("m"))
    }

    func testElapsedTimeFormatterHours() {
        let hour = ElapsedTimeFormatter.format(3600)
        XCTAssertTrue(hour.contains("h"))
    }
}
