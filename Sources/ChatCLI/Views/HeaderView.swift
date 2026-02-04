//
//  HeaderView.swift
//  ChatCLI
//
//  Header view showing model, working directory, and git branch
//

import SwiftTUI
import Foundation

/// Header view displaying context information
struct HeaderView: View {
    let modelName: String
    let workingDirectory: String
    let gitBranch: String?

    var body: some View {
        HStack {
            Text("SwiftClaude")
                .bold()
                .foregroundColor(.cyan)

            Spacer()

            Text(modelName)
                .foregroundColor(.yellow)

            Spacer()

            Text(shortPath(workingDirectory))
                .foregroundColor(.blue)

            if let branch = gitBranch {
                Text(" (\(branch))")
                    .foregroundColor(.magenta)
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
extension HeaderView {
    static var preview: HeaderView {
        HeaderView(
            modelName: "claude-3-sonnet",
            workingDirectory: "/Users/user/project",
            gitBranch: "main"
        )
    }
}
#endif
