//
//  InfoLineView.swift
//  CLI
//
//  Info line displayed above the input showing model, path, git branch, etc.
//

import SwiftTUI
import Foundation

/// Configurable info line displayed above the input field
struct InfoLineView: View {
    let modelName: String
    let workingDirectory: String
    let gitBranch: String?
    let messageCount: Int
    let config: InfoLineConfig

    var body: some View {
        HStack {
            if config.showModel {
                Text(modelName)
                    .foregroundColor(.yellow)
            }

            Spacer()

            if config.showWorkingDir {
                Text(shortPath(workingDirectory))
                    .foregroundColor(.blue)
            }

            if config.showGitBranch, let branch = gitBranch {
                Text(" (\(branch))")
                    .foregroundColor(.magenta)
            }

            if config.showMessageCount {
                Text(" [\(messageCount)]")
                    .foregroundColor(.white)
            }
        }
    }

    /// Shorten path by replacing home directory with ~
    private func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// MARK: - Preview

#if DEBUG
extension InfoLineView {
    static var preview: InfoLineView {
        InfoLineView(
            modelName: "claude-3-sonnet",
            workingDirectory: "/Users/user/project",
            gitBranch: "main",
            messageCount: 5,
            config: InfoLineConfig()
        )
    }
}
#endif
