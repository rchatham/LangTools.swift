//
//  Configuration.swift
//  CLI
//
//  Configuration and settings management for LangTools CLI
//

import Foundation

/// Application configuration settings
struct Configuration {
    /// Current LLM model selection
    var model: Model

    /// Current color theme
    var theme: Theme = .default

    /// Working directory for file operations
    var workingDirectory: String

    /// Whether to auto-approve safe tools
    var autoApproveTools: Set<String> = ["Read", "Glob", "Grep"]

    /// Maximum input history size
    var historySize: Int = 100

    /// Whether streaming responses are enabled
    var streamingEnabled: Bool = true

    /// Info line configuration (above input)
    var infoLine: InfoLineConfig = InfoLineConfig()

    /// Status line configuration (bottom)
    var statusLine: StatusLineConfig = StatusLineConfig()

    /// Initialize with current environment
    init() {
        self.model = UserDefaults.model
        self.workingDirectory = FileManager.default.currentDirectoryPath
    }

    /// Load configuration from user defaults or config file
    static func load() -> Configuration {
        var config = Configuration()

        // Load from UserDefaults
        config.model = UserDefaults.model

        // Load from config file if it exists
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".langtools")
            .appendingPathComponent("config.json")

        if let data = try? Data(contentsOf: configPath),
           let userConfig = try? JSONDecoder().decode(UserConfig.self, from: data) {
            config.theme = Theme(rawValue: userConfig.theme) ?? .default
            config.autoApproveTools = Set(userConfig.autoApproveTools)
            config.historySize = userConfig.historySize
            config.streamingEnabled = userConfig.streamingEnabled
            config.infoLine = userConfig.infoLine
            config.statusLine = userConfig.statusLine
        }

        return config
    }

    /// Save configuration to file
    func save() throws {
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".langtools")

        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

        let userConfig = UserConfig(
            theme: theme.rawValue,
            defaultModel: model.rawValue,
            autoApproveTools: Array(autoApproveTools),
            historySize: historySize,
            streamingEnabled: streamingEnabled,
            shortcuts: [:],
            infoLine: infoLine,
            statusLine: statusLine
        )

        let data = try JSONEncoder().encode(userConfig)
        let configPath = configDir.appendingPathComponent("config.json")
        try data.write(to: configPath)
    }
}

/// User configuration file structure
struct UserConfig: Codable {
    var theme: String = "default"
    var defaultModel: String = "claude-3-sonnet"
    var autoApproveTools: [String] = ["Read", "Glob", "Grep"]
    var historySize: Int = 100
    var streamingEnabled: Bool = true
    var shortcuts: [String: String] = [:]
    var infoLine: InfoLineConfig = InfoLineConfig()
    var statusLine: StatusLineConfig = StatusLineConfig()
}

/// Configuration for the info line displayed above the input
struct InfoLineConfig: Codable {
    var showModel: Bool = true
    var showWorkingDir: Bool = true
    var showGitBranch: Bool = true
    var showTokenCount: Bool = false
    var showMessageCount: Bool = false
}

/// Configuration for the status line displayed at the bottom
struct StatusLineConfig: Codable {
    var showToolExecution: Bool = true
    var showErrorMessages: Bool = true
}

/// Color theme options
enum Theme: String, CaseIterable {
    case `default`
    case minimal
    case dark
    case light

    var userMessageColor: ANSIColor {
        switch self {
        case .default, .dark: return .green
        case .minimal, .light: return .default
        }
    }

    var assistantMessageColor: ANSIColor {
        switch self {
        case .default, .dark: return .yellow
        case .minimal, .light: return .default
        }
    }

    var toolStatusColor: ANSIColor {
        switch self {
        case .default, .dark: return .cyan
        case .minimal, .light: return .default
        }
    }

    var errorColor: ANSIColor {
        return .red
    }

    var headerColor: ANSIColor {
        switch self {
        case .default, .dark: return .blue
        case .minimal, .light: return .default
        }
    }

    var inputPromptColor: ANSIColor {
        switch self {
        case .default, .dark: return .green
        case .minimal, .light: return .default
        }
    }
}
