#if canImport(AppKit)
import AppKit
import HelperCore

@main
struct LangToolsHelperApp {
    static func main() {
        MainActor.assumeIsolated {
            let application = NSApplication.shared
            let delegate = HelperAppDelegate()
            application.delegate = delegate
            application.setActivationPolicy(.accessory)
            withExtendedLifetime(delegate) {
                application.run()
            }
        }
    }
}

/// Nonisolated constants for the helper app so they can be used from default
/// arguments and nonisolated contexts.
enum HelperAppDefaults {
    /// The helper always binds loopback; this is the port the example app
    /// expects by default and that pairing URLs carry.
    static let host = "127.0.0.1"
    static let port: UInt16 = 8765
}

@MainActor
final class HelperAppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let tokenController: TokenFileController
    private let host: String
    private let port: UInt16
    private var bearerToken: String?
    private var serverTask: Task<Void, Never>?
    /// Set when the user asked to stop the server, so a resulting error is
    /// not reported as an unexpected failure.
    private var isUserStop = false

    private var isRunning: Bool { serverTask != nil }

    init(tokenFileURL: URL = TokenFileController.defaultTokenFileURL, port: UInt16 = HelperAppDefaults.port) {
        self.tokenController = TokenFileController(tokenFileURL: tokenFileURL)
        self.host = HelperAppDefaults.host
        self.port = port
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        rebuildMenu()
        startServer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        serverTask?.cancel()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: Menu

    private func configureStatusItem() {
        let symbol = NSImage(
            systemSymbolName: "antenna.radiowaves.left.and.right",
            accessibilityDescription: "LangTools Helper"
        ) ?? NSImage(systemSymbolName: "network", accessibilityDescription: "LangTools Helper")
        symbol?.isTemplate = true
        statusItem.button?.image = symbol
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let statusMenuItem = NSMenuItem(
            title: isRunning ? "Running at http://\(host):\(port)" : "Stopped",
            action: nil,
            keyEquivalent: ""
        )
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        let toggleItem = NSMenuItem(
            title: isRunning ? "Stop Helper" : "Start Helper",
            action: #selector(toggleServer),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        let pairItem = NSMenuItem(
            title: "Pair with LangTools Example…",
            action: #selector(pairWithExample),
            keyEquivalent: ""
        )
        pairItem.target = self
        pairItem.isEnabled = isRunning
        menu.addItem(pairItem)

        let copyItem = NSMenuItem(
            title: "Copy Token",
            action: #selector(copyToken),
            keyEquivalent: ""
        )
        copyItem.target = self
        copyItem.isEnabled = bearerToken != nil
        menu.addItem(copyItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "Quit LangTools Helper",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: Server lifecycle

    private func startServer() {
        guard serverTask == nil else { return }
        let token: String
        do {
            token = try tokenController.ensureToken()
        } catch {
            bearerToken = nil
            presentError(error, title: "LangTools Helper could not read its token file.")
            rebuildMenu()
            return
        }
        bearerToken = token
        let server = LocalHelperServer(host: host, port: port, bearerToken: token)
        isUserStop = false
        serverTask = Task.detached { [weak self] in
            do {
                try await server.run()
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.isUserStop == false else { return }
                    self.presentError(error, title: "The LangTools Helper server stopped.")
                }
            }
            await MainActor.run { [weak self] in
                self?.serverDidStop()
            }
        }
        rebuildMenu()
    }

    private func stopServer() {
        guard serverTask != nil else { return }
        isUserStop = true
        serverTask?.cancel()
    }

    private func serverDidStop() {
        serverTask = nil
        rebuildMenu()
    }

    // MARK: Actions

    @objc private func toggleServer() {
        if isRunning {
            stopServer()
        } else {
            startServer()
        }
    }

    @objc private func pairWithExample() {
        guard let token = bearerToken else { return }
        do {
            let url = try PairingURL.make(port: port, token: token)
            guard NSWorkspace.shared.open(url) else {
                throw PairingURLOpenError.noAppForURL
            }
        } catch {
            presentError(
                error,
                title: "Unable to open the LangTools Example pairing URL."
            )
        }
    }

    @objc private func copyToken() {
        guard let token = bearerToken else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(token, forType: .string)
    }

    @objc private func quit() {
        serverTask?.cancel()
        isUserStop = true
        Task.detached {
            await CodexRuntimeService.shared.shutdown()
            await MainActor.run {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    // MARK: Errors

    private enum PairingURLOpenError: LocalizedError {
        case noAppForURL

        var errorDescription: String? {
            "macOS could not open the pairing link. Make sure LangTools_Example is installed and can handle the langtools-example-auth scheme."
        }
    }

    private func presentError(_ error: Error, title: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
#else
import Foundation

// Non-macOS platforms have no menu bar; keep the target buildable so the
// package still compiles cross-platform.
@main
enum LangToolsHelperMain {
    static func main() {
        FileHandle.standardError.write(Data("LangTools Helper requires macOS.\n".utf8))
    }
}
#endif