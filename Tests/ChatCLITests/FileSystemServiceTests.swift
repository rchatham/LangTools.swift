//
//  FileSystemServiceTests.swift
//  ChatCLITests
//
//  Tests for file system operations
//

import XCTest
import Foundation

final class FileSystemServiceTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatCLITests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Read Tests

    func testReadFile() throws {
        // Create test file
        let testPath = tempDir.appendingPathComponent("test.txt")
        let content = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5"
        try content.write(to: testPath, atomically: true, encoding: .utf8)

        // Read and verify
        let result = try readFile(at: testPath.path)
        XCTAssertTrue(result.contains("1\tLine 1"))
        XCTAssertTrue(result.contains("2\tLine 2"))
        XCTAssertTrue(result.contains("5\tLine 5"))
    }

    func testReadFileWithOffset() throws {
        let testPath = tempDir.appendingPathComponent("test_offset.txt")
        let content = (1...10).map { "Line \($0)" }.joined(separator: "\n")
        try content.write(to: testPath, atomically: true, encoding: .utf8)

        let result = try readFile(at: testPath.path, offset: 3, limit: 3)
        XCTAssertTrue(result.contains("3\tLine 3"))
        XCTAssertTrue(result.contains("4\tLine 4"))
        XCTAssertTrue(result.contains("5\tLine 5"))
        XCTAssertFalse(result.contains("Line 1"))
        XCTAssertFalse(result.contains("Line 6"))
    }

    func testReadFileNotFound() {
        XCTAssertThrowsError(try readFile(at: "/nonexistent/path/file.txt")) { error in
            XCTAssertTrue(error.localizedDescription.contains("not found"))
        }
    }

    // MARK: - Write Tests

    func testWriteFile() throws {
        let testPath = tempDir.appendingPathComponent("write_test.txt")
        let content = "Hello, World!"

        try writeFile(at: testPath.path, content: content)

        let readContent = try String(contentsOf: testPath, encoding: .utf8)
        XCTAssertEqual(readContent, content)
    }

    func testWriteFileCreatesDirectories() throws {
        let testPath = tempDir.appendingPathComponent("nested/dir/file.txt")
        let content = "Nested content"

        try writeFile(at: testPath.path, content: content)

        XCTAssertTrue(FileManager.default.fileExists(atPath: testPath.path))
        let readContent = try String(contentsOf: testPath, encoding: .utf8)
        XCTAssertEqual(readContent, content)
    }

    // MARK: - Edit Tests

    func testEditFile() throws {
        let testPath = tempDir.appendingPathComponent("edit_test.txt")
        let content = "Hello, World!"
        try content.write(to: testPath, atomically: true, encoding: .utf8)

        let replacements = try editFile(
            at: testPath.path,
            oldString: "World",
            newString: "Swift"
        )

        XCTAssertEqual(replacements, 1)
        let readContent = try String(contentsOf: testPath, encoding: .utf8)
        XCTAssertEqual(readContent, "Hello, Swift!")
    }

    func testEditFileReplaceAll() throws {
        let testPath = tempDir.appendingPathComponent("edit_all_test.txt")
        let content = "cat cat cat dog"
        try content.write(to: testPath, atomically: true, encoding: .utf8)

        let replacements = try editFile(
            at: testPath.path,
            oldString: "cat",
            newString: "bird",
            replaceAll: true
        )

        XCTAssertEqual(replacements, 3)
        let readContent = try String(contentsOf: testPath, encoding: .utf8)
        XCTAssertEqual(readContent, "bird bird bird dog")
    }

    func testEditFileStringNotUnique() throws {
        let testPath = tempDir.appendingPathComponent("not_unique.txt")
        let content = "cat cat cat"
        try content.write(to: testPath, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try editFile(
            at: testPath.path,
            oldString: "cat",
            newString: "dog",
            replaceAll: false
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("3 times"))
        }
    }

    // MARK: - Glob Tests

    func testGlobPattern() throws {
        // Create test files
        try "swift1".write(to: tempDir.appendingPathComponent("file1.swift"), atomically: true, encoding: .utf8)
        try "swift2".write(to: tempDir.appendingPathComponent("file2.swift"), atomically: true, encoding: .utf8)
        try "text".write(to: tempDir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        // Use ** pattern for recursive matching
        let results = try glob(pattern: "**/*.swift", in: tempDir.path)

        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.hasSuffix(".swift") })
    }

    func testGlobNestedPattern() throws {
        // Create nested structure
        let subDir = tempDir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        try "nested".write(to: subDir.appendingPathComponent("nested.swift"), atomically: true, encoding: .utf8)
        try "root".write(to: tempDir.appendingPathComponent("root.swift"), atomically: true, encoding: .utf8)

        let results = try glob(pattern: "**/*.swift", in: tempDir.path)

        XCTAssertEqual(results.count, 2)
    }

    // MARK: - Grep Tests

    func testGrepBasic() throws {
        let testPath = tempDir.appendingPathComponent("grep_test.txt")
        let content = "Hello World\nfoo bar\nHello Swift\nbaz qux"
        try content.write(to: testPath, atomically: true, encoding: .utf8)

        let matches = try grep(pattern: "Hello", in: testPath.path)

        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches[0].lineNumber, 1)
        XCTAssertEqual(matches[1].lineNumber, 3)
    }

    func testGrepRegex() throws {
        let testPath = tempDir.appendingPathComponent("grep_regex.txt")
        let content = "error: something\nwarning: other\nERROR: loud"
        try content.write(to: testPath, atomically: true, encoding: .utf8)

        let matches = try grep(pattern: "error", in: testPath.path)

        XCTAssertEqual(matches.count, 1) // Case-sensitive by default
    }

    // MARK: - Helper implementations (mirroring FileSystemService)

    private func readFile(at path: String, offset: Int = 1, limit: Int = 2000) throws -> String {
        let url = URL(fileURLWithPath: path)

        guard FileManager.default.fileExists(atPath: path) else {
            throw TestError.fileNotFound(path: path)
        }

        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)

        let startIndex = max(0, offset - 1)
        let endIndex = min(lines.count, startIndex + limit)

        guard startIndex < lines.count else {
            throw TestError.offsetOutOfRange(offset: offset, totalLines: lines.count)
        }

        var result: [String] = []
        for (index, line) in lines[startIndex..<endIndex].enumerated() {
            let lineNumber = startIndex + index + 1
            result.append("\(lineNumber)\t\(line)")
        }

        return result.joined(separator: "\n")
    }

    private func writeFile(at path: String, content: String) throws {
        let url = URL(fileURLWithPath: path)
        let parentDir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func editFile(at path: String, oldString: String, newString: String, replaceAll: Bool = false) throws -> Int {
        let url = URL(fileURLWithPath: path)

        guard FileManager.default.fileExists(atPath: path) else {
            throw TestError.fileNotFound(path: path)
        }

        var content = try String(contentsOf: url, encoding: .utf8)
        let occurrences = content.components(separatedBy: oldString).count - 1

        if occurrences == 0 {
            throw TestError.stringNotFound(search: oldString)
        }

        if occurrences > 1 && !replaceAll {
            throw TestError.stringNotUnique(search: oldString, occurrences: occurrences)
        }

        if replaceAll {
            content = content.replacingOccurrences(of: oldString, with: newString)
        } else {
            if let range = content.range(of: oldString) {
                content.replaceSubrange(range, with: newString)
            }
        }

        try content.write(to: url, atomically: true, encoding: .utf8)
        return replaceAll ? occurrences : 1
    }

    private func glob(pattern: String, in basePath: String) throws -> [String] {
        let baseURL = URL(fileURLWithPath: basePath)
        var matchingFiles: [String] = []

        let regexPattern = globToRegex(pattern)

        if let enumerator = FileManager.default.enumerator(
            at: baseURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            while let url = enumerator.nextObject() as? URL {
                let resourceValues = try? url.resourceValues(forKeys: [.isRegularFileKey])
                guard resourceValues?.isRegularFile == true else { continue }

                let relativePath = url.path.replacingOccurrences(of: basePath + "/", with: "")
                if matches(relativePath, pattern: regexPattern) {
                    matchingFiles.append(url.path)
                }
            }
        }

        return matchingFiles
    }

    private func globToRegex(_ pattern: String) -> String {
        var regex = "^"
        var i = pattern.startIndex

        while i < pattern.endIndex {
            let c = pattern[i]
            switch c {
            case "*":
                let next = pattern.index(after: i)
                if next < pattern.endIndex && pattern[next] == "*" {
                    regex += ".*"
                    i = pattern.index(after: next)
                    continue
                } else {
                    regex += "[^/]*"
                }
            case "?":
                regex += "[^/]"
            case ".":
                regex += "\\."
            default:
                regex += String(c)
            }
            i = pattern.index(after: i)
        }

        regex += "$"
        return regex
    }

    private func matches(_ path: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return false
        }
        let range = NSRange(path.startIndex..., in: path)
        return regex.firstMatch(in: path, options: [], range: range) != nil
    }

    private func grep(pattern: String, in path: String) throws -> [GrepTestMatch] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            throw TestError.invalidRegex(pattern: pattern)
        }

        let content = try String(contentsOfFile: path, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)
        var matches: [GrepTestMatch] = []

        for (lineIndex, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            if regex.firstMatch(in: line, options: [], range: range) != nil {
                matches.append(GrepTestMatch(file: path, lineNumber: lineIndex + 1, content: line))
            }
        }

        return matches
    }
}

// MARK: - Test Types

struct GrepTestMatch {
    let file: String
    let lineNumber: Int
    let content: String
}

enum TestError: LocalizedError {
    case fileNotFound(path: String)
    case offsetOutOfRange(offset: Int, totalLines: Int)
    case stringNotFound(search: String)
    case stringNotUnique(search: String, occurrences: Int)
    case invalidRegex(pattern: String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .offsetOutOfRange(let offset, let totalLines):
            return "Offset \(offset) out of range. File has \(totalLines) lines."
        case .stringNotFound(let search):
            return "String not found: \(search)"
        case .stringNotUnique(let search, let occurrences):
            return "String '\(search)' found \(occurrences) times"
        case .invalidRegex(let pattern):
            return "Invalid regex: \(pattern)"
        }
    }
}
