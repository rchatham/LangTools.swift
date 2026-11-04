//
//  SystemOneRouting.swift
//  LangToolsApp
//
//  Optional on-device tool routing with System One. Off by default: d1 takes
//  about 2.35 GB at float32, and the app works without it.
//

import Chat
import Combine
import Foundation
import SwiftUI
import SystemOneD1
import SystemOneLangTools

/// Loads the router the settings describe and hands it to `MessageService`.
///
/// Settings live in `UserDefaults`, so launch arguments override them for a run:
/// `-systemOneRouting 1 -systemOneBackend server -systemOneServerURL <url>`.
@MainActor
final class SystemOneRoutingController: ObservableObject {
    enum Backend: String, CaseIterable, Identifiable {
        case onDevice
        case server

        var id: Self { self }

        var label: String {
            switch self {
            case .onDevice: return "d1 on this device"
            case .server: return "system-one serve"
            }
        }

        /// MLX needs Metal GPU features the iOS Simulator does not provide.
        static var supportsOnDevice: Bool {
            #if targetEnvironment(simulator)
            return false
            #else
            return true
            #endif
        }
    }

    enum State: Equatable {
        case off
        case loading
        case ready
        case failed(String)
    }

    /// Phrased as the request each agent handles, which is what d1 routes on.
    static let routingDescriptions = [
        "calendarAgent": "Their calendar, events, meetings, or schedule",
        "reminderAgent": "To be reminded of something, or their to-do lists, shopping lists, or tasks",
        "researchAgent": "To look something up on the web or research a topic",
        "current_date_time": "The current date, day, or time",
        "calculate": "To calculate a number or do math",
    ]

    static let defaultServerURL = "http://127.0.0.1:8083/v1/systemone"

    @Published private(set) var state = State.off
    @Published private(set) var modelFolder: URL?
    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Keys.enabled) }
    }
    @Published var backend: Backend {
        didSet { defaults.set(backend.rawValue, forKey: Keys.backend) }
    }
    @Published var serverURL: String {
        didSet { defaults.set(serverURL, forKey: Keys.serverURL) }
    }
    @Published var precision: D1Precision {
        didSet { defaults.set(precision.rawValue, forKey: Keys.precision) }
    }

    private enum Keys {
        static let enabled = "systemOneRouting"
        static let backend = "systemOneBackend"
        static let serverURL = "systemOneServerURL"
        static let precision = "systemOnePrecision"
        static let modelFolder = "systemOneModelFolder"
        static let modelFolderBookmark = "systemOneModelFolderBookmark"
    }

    private let defaults: UserDefaults
    private weak var messageService: MessageService?
    private var loadTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Keys.enabled)
        let storedBackend = Backend(rawValue: defaults.string(forKey: Keys.backend) ?? "")
        backend = Backend.supportsOnDevice ? (storedBackend ?? .onDevice) : .server
        serverURL = defaults.string(forKey: Keys.serverURL) ?? Self.defaultServerURL
        #if os(iOS)
        let defaultPrecision = D1Precision.float16
        #else
        let defaultPrecision = D1Precision.float32
        #endif
        precision = D1Precision(rawValue: defaults.string(forKey: Keys.precision) ?? "") ?? defaultPrecision
        modelFolder = Self.resolveModelFolder(defaults)
    }

    /// Attaches the service and loads the router if routing is on.
    func attach(to service: MessageService) {
        messageService = service
        reload()
    }

    /// Applies the current settings. Messages keep every tool until a load
    /// finishes, because routing is an optimization and must never block a send.
    func reload() {
        loadTask?.cancel()
        messageService?.toolRouter = nil
        guard isEnabled else {
            state = .off
            return
        }
        state = .loading
        let backend = backend
        let serverURL = serverURL
        let modelFolder = modelFolder
        let precision = precision
        loadTask = Task { [weak self] in
            do {
                let router = try await Self.makeRouter(
                    backend: backend,
                    serverURL: serverURL,
                    modelFolder: modelFolder,
                    precision: precision
                )
                try Task.checkCancellation()
                self?.messageService?.toolRouter = router
                self?.state = .ready
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    /// Remembers a folder picked in the file importer across launches.
    func chooseModelFolder(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            #if os(macOS)
            let bookmark = try url.bookmarkData(options: .withSecurityScope)
            #else
            let bookmark = try url.bookmarkData()
            #endif
            defaults.set(bookmark, forKey: Keys.modelFolderBookmark)
            defaults.removeObject(forKey: Keys.modelFolder)
            modelFolder = url
        } catch {
            state = .failed("Could not remember the folder: \(error.localizedDescription)")
        }
    }

    private nonisolated static func makeRouter(
        backend: Backend,
        serverURL: String,
        modelFolder: URL?,
        precision: D1Precision
    ) async throws -> SystemOneToolRouter {
        switch backend {
        case .server:
            guard let url = URL(string: serverURL), url.scheme != nil else {
                throw SystemOneRoutingError.invalidServerURL(serverURL)
            }
            return try await .server(endpoint: url, routingDescriptions: routingDescriptions)
        case .onDevice:
            guard let modelFolder else { throw SystemOneRoutingError.noModelFolder }
            let scoped = modelFolder.startAccessingSecurityScopedResource()
            defer { if scoped { modelFolder.stopAccessingSecurityScopedResource() } }
            return try await .d1(
                modelFolder: modelFolder,
                precision: precision,
                routingDescriptions: routingDescriptions
            )
        }
    }

    /// A `-systemOneModelFolder` path wins over a folder picked in Settings.
    private static func resolveModelFolder(_ defaults: UserDefaults) -> URL? {
        if let path = defaults.string(forKey: Keys.modelFolder), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        guard let bookmark = defaults.data(forKey: Keys.modelFolderBookmark) else { return nil }
        var isStale = false
        #if os(macOS)
        return try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &isStale)
        #else
        return try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale)
        #endif
    }
}

enum SystemOneRoutingError: LocalizedError {
    case invalidServerURL(String)
    case noModelFolder

    var errorDescription: String? {
        switch self {
        case .invalidServerURL(let url):
            return "'\(url)' is not a URL."
        case .noModelFolder:
            return "Choose the d1-omni-600M folder."
        }
    }
}

/// The System One rows in Settings.
struct SystemOneRoutingSettings: View {
    @ObservedObject var controller: SystemOneRoutingController
    @State private var choosingFolder = false

    var body: some View {
        Toggle("Route Tools with System One", isOn: $controller.isEnabled)
            .onChange(of: controller.isEnabled) { controller.reload() }
        if controller.isEnabled {
            if SystemOneRoutingController.Backend.supportsOnDevice {
                Picker("Router", selection: $controller.backend) {
                    ForEach(SystemOneRoutingController.Backend.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: controller.backend) { controller.reload() }
            }
            switch controller.backend {
            case .server:
                TextField("Endpoint", text: $controller.serverURL)
                    .autocorrectionDisabled()
                    .onSubmit { controller.reload() }
            case .onDevice:
                LabeledContent("Folder", value: controller.modelFolder?.lastPathComponent ?? "Not chosen")
                Button("Choose d1-omni-600M Folder…") { choosingFolder = true }
                Picker("Precision", selection: $controller.precision) {
                    Text("float32").tag(D1Precision.float32)
                    Text("float16").tag(D1Precision.float16)
                }
                .onChange(of: controller.precision) { controller.reload() }
            }
            status
        }
        Text("d1 scores the tools for each message, and the model only receives the plausible ones.")
            .font(.caption)
            .foregroundColor(.secondary)
            .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    controller.chooseModelFolder(url)
                    controller.reload()
                }
            }
    }

    @ViewBuilder
    private var status: some View {
        switch controller.state {
        case .off:
            EmptyView()
        case .loading:
            Label {
                Text("Loading…")
            } icon: {
                ProgressView().controlSize(.small)
            }
        case .ready:
            Label("Routing", systemImage: "checkmark.circle")
                .foregroundColor(.green)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text(message).foregroundColor(.red)
                Button("Retry") { controller.reload() }
            }
        }
    }
}
