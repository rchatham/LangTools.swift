#if canImport(AppKit)
import AppKit
import SwiftUI
import CoreImage.CIFilterBuiltins
import HelperCore
import HelperLink

/// All view-state changes occur on the main actor. Networking starts only after explicit LAN opt-in.
@MainActor
final class MobilePairingController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var interfaces = MobileLANInterface.available()
    @Published var selectedInterfaceID: String = ""
    @Published private(set) var enabled = false
    @Published private(set) var starting = false
    @Published private(set) var status = "LAN access is disabled. The existing desktop helper stays loopback-only."
    @Published private(set) var errorText: String?
    @Published private(set) var qrImage: NSImage?
    @Published private(set) var expiry: Date?
    @Published private(set) var remainingSeconds = 0
    @Published private(set) var devices: [MobileDevice] = []
    @Published private(set) var address: String?
    @Published private(set) var helperName = "Mac"
    @Published private(set) var codexEnabled = false
    @Published private(set) var claudeEnabled = false
    @Published private(set) var claudeBackendAddress = "http://127.0.0.1:8080"
    var capabilities: [String] {
        (["ollama"] + (codexEnabled ? ["codex"] : []) + (claudeEnabled ? ["claude"] : [])).sorted()
    }
    var capabilityLabel: String { capabilities.map { $0 == "codex" ? "Codex" : $0 == "claude" ? "Claude Code" : "Ollama" }.joined(separator: ", ") }
    private var identity: MobileTLSIdentity?
    private var identityTask: Task<MobileTLSIdentity, Error>?
    private var store: MobileDeviceStore?
    private var server: MobileOllamaServer?
    private var serverTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var window: NSWindow?
    private var generation = UUID()
    private var actualPort: UInt16?
    private var pairedDeviceIDs: Set<String> = []
    // Closing cancels pairing intent, not explicitly enabled LAN access for saved devices.
    private var pairingIntent: UUID?
    private(set) var activeCode: String?
    private let loadIdentity: @Sendable () async throws -> MobileTLSIdentity
    private let makeStore: (MobileTLSIdentity) throws -> MobileDeviceStore
    private let makeServer: (String, MobileTLSIdentity, MobileDeviceStore, @escaping @Sendable (UInt16) -> Void) throws -> MobileOllamaServer

    override convenience init() {
        self.init(loadIdentity: { try MobileTLSIdentity.loadOrCreate() },
                  makeStore: { try MobileDeviceStore(helperID: $0.helperID) },
                  makeServer: { MobileOllamaServer(host: $0, identity: $1, devices: $2, onReady: $3) })
    }

    /// Internal dependency injection keeps lifecycle tests off the real keychain, store and fixed LAN port.
    init(loadIdentity: @escaping @Sendable () async throws -> MobileTLSIdentity,
         makeStore: @escaping (MobileTLSIdentity) throws -> MobileDeviceStore,
         makeServer: @escaping (String, MobileTLSIdentity, MobileDeviceStore, @escaping @Sendable (UInt16) -> Void) throws -> MobileOllamaServer) {
        self.loadIdentity = loadIdentity
        self.makeStore = makeStore
        self.makeServer = makeServer
        super.init()
        selectedInterfaceID = interfaces.first?.id ?? ""
        let name = Host.current().localizedName ?? "Mac"
        helperName = MobileHelperPairingPayload.isDisplayName(name) ? name : "Mac"
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 760),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Connect iPhone — LangToolsHelper"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: MobilePairingView(controller: self))
            window.center()
            self.window = window
        }
        startMonitoring()
        Task {
            do {
                _ = try await prepareStore()
                devices = await store?.devices() ?? []
                pairedDeviceIDs = Set(devices.map(\.id))
            } catch { errorText = error.localizedDescription }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { cancelPairing() }

    /// Scope/config changes stop and drain current requests, invalidate pending QR, and require explicit re-enable.
    func setCodexEnabled(_ value: Bool) {
        guard value != codexEnabled else { return }
        codexEnabled = value
        configurationChanged()
    }

    func setClaudeEnabled(_ value: Bool) {
        guard value != claudeEnabled else { return }
        claudeEnabled = value
        configurationChanged()
    }

    func setClaudeBackendAddress(_ value: String) {
        guard value != claudeBackendAddress else { return }
        claudeBackendAddress = value
        configurationChanged()
    }

    private func configurationChanged() {
        disable()
        status = "Provider scope changed. Existing device grants are unchanged; explicitly re-enable and pair again for new access."
    }

    func setEnabled(_ value: Bool) {
        if !value { disable(); return }
        let scope = capabilities
        let claudeURL: URL?
        do {
            if claudeEnabled {
                guard let url = URL(string: claudeBackendAddress) else { throw MobileHelperError.upstreamRejected }
                claudeURL = try MobileClaudeRelay.validatedOrigin(url)
            } else { claudeURL = nil }
        } catch {
            errorText = "Claude Code requires a fixed http://127.0.0.1:<port> or http://[::1]:<port> external backend origin."
            return
        }
        guard serverTask == nil, let selected = interfaces.first(where: { $0.id == selectedInterfaceID }) else {
            errorText = MobileHelperError.invalidInterface.localizedDescription; return
        }
        generation = UUID()
        let current = generation
        let intent = UUID()
        pairingIntent = intent
        starting = true
        enabled = true
        errorText = nil
        status = "Creating encrypted helper identity…"
        serverTask = Task { [weak self] in
            guard let self else { return }
            do {
                // OpenSSL/keychain work never blocks SwiftUI rendering or the main run loop.
                let store = try await prepareStore()
                try Task.checkCancellation()
                guard let identity = self.identity else { throw MobileHelperError.invalidIdentity }
                guard generation == current, enabled else { return }
                self.identity = identity
                self.store = store
                self.devices = await store.devices()
                guard generation == current, enabled else { return }
                self.pairedDeviceIDs = Set(devices.map(\.id))
                self.address = selected.address
                let server = try makeServer(selected.address, identity, store, { [weak self] port in
                    Task { @MainActor in
                        guard let self, self.generation == current, self.enabled else { return }
                        self.actualPort = port
                        self.starting = false
                        self.status = "Encrypted access (\(self.capabilityLabel)) at \(selected.address):\(port)"
                        // Readiness may arrive after close/cancel, even during identity creation.
                        guard self.pairingIntent == intent else { return }
                        await self.refreshPairing(intent: intent, generation: current)
                    }
                })
                guard generation == current, enabled else { return }
                self.server = server
                try await server.configure(capabilities: scope, claudeBackendURL: claudeURL)
                guard generation == current, enabled else { return }
                try await server.run()
            } catch is CancellationError {
                // Explicit LAN disable or app shutdown interrupted the listener.
            } catch {
                guard self.generation == current else { return }
                self.errorText = error.localizedDescription
            }
            guard self.generation == current else { return }
            self.enabled = false
            self.starting = false
            self.serverTask = nil
            self.server = nil
            self.actualPort = nil
            self.cancelPairing()
            await self.store?.cancelPairing()
            guard self.generation == current, !self.enabled else { return }
            self.status = "LAN listener stopped. Paired devices cannot connect."
        }
    }

    private func prepareStore() async throws -> MobileDeviceStore {
        if let store { return store }
        if identityTask == nil {
            let loadIdentity = self.loadIdentity
            identityTask = Task.detached { try await loadIdentity() }
        }
        guard let identityTask else { throw MobileHelperError.invalidIdentity }
        do {
            let identity = try await identityTask.value
            // Another MainActor continuation may already have opened the store.
            if let store { return store }
            let store = try makeStore(identity)
            self.identity = identity
            self.store = store
            return store
        } catch {
            self.identityTask = nil
            throw error
        }
    }

    private func disable() {
        generation = UUID()
        let current = generation
        cancelPairing()
        serverTask?.cancel()
        // Do not permit a restart until cancelled connections have drained.
        let task = serverTask
        starting = task != nil
        enabled = false
        qrImage = nil
        expiry = nil
        actualPort = nil
        let store = self.store
        status = "Stopping encrypted LAN listener…"
        Task { [weak self] in
            await store?.cancelPairing()
            await task?.value
            guard let self, self.generation == current, !self.enabled else { return }
            self.serverTask = nil
            self.server = nil
            self.starting = false
            self.status = "LAN access is disabled. Desktop pairing is unaffected."
        }
    }

    func shutdown() { monitorTask?.cancel(); disable() }

    @discardableResult
    func refresh() -> Task<Void, Never>? {
        guard enabled, !starting else { return nil }
        // Establish intent before scheduling so close/cancel also invalidates queued refreshes.
        let intent = UUID()
        pairingIntent = intent
        let current = generation
        return Task { await refreshPairing(intent: intent, generation: current) }
    }

    private func refreshPairing(intent: UUID, generation current: UUID) async {
        guard generation == current, pairingIntent == intent, enabled, !starting,
              let store, let identity, let address, let actualPort else { return }
        var generatedCode: String?
        do {
            let code = try await store.generatePairingCode()
            generatedCode = code.code
            guard generation == current, pairingIntent == intent, enabled else {
                await store.cancelPairing(code: code.code); return
            }
            activeCode = code.code
            let payload = try pairingPayload(endpoint: URL(string: "https://\(address):\(actualPort)")!,
                                             identity: identity, code: code.code)
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(try payload.pairingURL().absoluteString.utf8)
            filter.correctionLevel = "M"
            guard let output = filter.outputImage,
                  let image = CIContext().createCGImage(output.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
                                                        from: output.extent.applying(CGAffineTransform(scaleX: 8, y: 8))) else {
                throw MobileHelperLinkError.invalidPayload
            }
            qrImage = NSImage(cgImage: image, size: NSSize(width: 300, height: 300))
            expiry = code.expiry
            remainingSeconds = 300
            errorText = nil
        } catch {
            // A stale refresh must never cancel a newer code or overwrite newer view state.
            if let generatedCode { await store.cancelPairing(code: generatedCode) }
            guard generation == current, pairingIntent == intent, enabled else { return }
            activeCode = nil
            qrImage = nil
            expiry = nil
            errorText = error.localizedDescription
        }
    }

    /// Preserve Ollama-only v1 links; v2 binds confirmation to optional account grants.
    private func pairingPayload(endpoint: URL, identity: MobileTLSIdentity, code: String) throws -> MobileHelperPairingPayload {
        let payload = MobileHelperPairingPayload(version: capabilities == ["ollama"] ? 1 : 2,
            endpoint: endpoint, helperID: identity.helperID, fingerprint: identity.fingerprint,
            code: code, name: helperName, capabilities: capabilities)
        try payload.validate()
        return payload
    }

    @discardableResult
    func cancelPairing() -> Task<Void, Never>? {
        pairingIntent = nil
        qrImage = nil
        expiry = nil
        remainingSeconds = 0
        let code = activeCode
        activeCode = nil
        let store = self.store
        guard let code else { return nil }
        return Task { await store?.cancelPairing(code: code) }
    }

    func revoke(_ device: MobileDevice) {
        guard let server else {
            guard let store else { return }
            Task {
                do { try await store.revoke(device.id); devices = await store.devices() }
                catch { errorText = error.localizedDescription }
            }
            return
        }
        Task {
            do { try await server.revokeDevice(device.id); devices = await store?.devices() ?? [] }
            catch { errorText = error.localizedDescription }
        }
    }

    private func startMonitoring() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                self.interfaces = MobileLANInterface.available()
                if self.enabled, !self.interfaces.contains(where: { $0.id == self.selectedInterfaceID }) {
                    self.disable()
                    self.errorText = "The selected network interface changed or disappeared. Re-enable LAN access and refresh pairing."
                }
                if let expiry = self.expiry {
                    self.remainingSeconds = max(0, Int(ceil(expiry.timeIntervalSinceNow)))
                    if self.remainingSeconds == 0 {
                        self.cancelPairing()
                        self.status = "QR expired. Refresh to create a new single-use pairing code."
                    }
                }
                if let store = self.store {
                    let devices = await store.devices()
                    let ids = Set(devices.map(\.id))
                    if !ids.subtracting(self.pairedDeviceIDs).isEmpty {
                        self.cancelPairing()
                        self.status = "iPhone paired. Granted provider access is ready."
                    }
                    self.pairedDeviceIDs = ids
                    self.devices = devices
                }
            }
        }
    }
}

private struct MobilePairingView: View {
    @ObservedObject var controller: MobilePairingController
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Connect iPhone").font(.largeTitle.bold())
                Text("\(controller.helperName) · \(controller.capabilityLabel)").font(.headline)
                Text("Keep iPhone and Mac on the same trusted local network. Optional account chat runs on this Mac; login/logout, admin routes and desktop helper credentials are not exposed. Codex retains the Mac runtime's native tool permissions; enable account access only for trusted phones.")
                    .foregroundStyle(.secondary)
                Picker("Private network interface", selection: $controller.selectedInterfaceID) {
                    ForEach(controller.interfaces) { interface in
                        Text("\(interface.name) · \(interface.address)").tag(interface.id)
                    }
                }
                .disabled(controller.enabled || controller.starting)
                Toggle("Allow Codex account chat and models (Mac runtime permissions)", isOn: Binding(
                    get: { controller.codexEnabled }, set: { controller.setCodexEnabled($0) }))
                Toggle("Allow external Claude Code backend relay", isOn: Binding(
                    get: { controller.claudeEnabled }, set: { controller.setClaudeEnabled($0) }))
                if controller.claudeEnabled {
                    TextField("Claude Code loopback backend origin", text: Binding(
                        get: { controller.claudeBackendAddress }, set: { controller.setClaudeBackendAddress($0) }))
                    Text("External backend only. Numeric loopback HTTP and explicit port required. Account tokens transit this Mac; sign in locally. No fallback if unavailable.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Changing provider scope or backend stops LAN access and invalidates the QR. Existing phones do not gain new capabilities; re-pair explicitly.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Allow encrypted iPhone access on this network", isOn: Binding(
                    get: { controller.enabled }, set: { controller.setEnabled($0) }))
                    .disabled(controller.starting)
                Text(controller.status).font(.callout).textSelection(.enabled)
                if let error = controller.errorText {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
                if controller.starting { ProgressView() }
                if let image = controller.qrImage {
                    HStack { Spacer(); Image(nsImage: image).interpolation(.none).resizable().frame(width: 300, height: 300)
                        .padding(12).background(.white); Spacer() }
                    Text("Scan with iPhone Camera, open LangTools, then confirm this Mac and \(controller.capabilityLabel) access.")
                    Text("Single-use QR expires in \(controller.remainingSeconds / 60):\(String(format: "%02d", controller.remainingSeconds % 60)).")
                        .font(.callout.monospacedDigit())
                } else if controller.enabled && !controller.starting {
                    Text("No active QR. Refresh when you are ready to pair.").foregroundStyle(.secondary)
                }
                HStack {
                    Button("Refresh QR") { controller.refresh() }.disabled(!controller.enabled || controller.starting)
                    Button("Cancel pairing") { controller.cancelPairing() }.disabled(controller.qrImage == nil)
                }
                Divider()
                Text("Paired devices").font(.headline)
                if controller.devices.isEmpty { Text("No paired iPhones.").foregroundStyle(.secondary) }
                ForEach(controller.devices) { device in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(device.name)
                            Text("\(device.capabilities.joined(separator: ", ")) · paired \(device.createdAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Revoke", role: .destructive) { controller.revoke(device) }
                    }
                }
                Text("Revoking interrupts active requests. Disabling LAN stops all iPhone access; saved devices reconnect only when you explicitly enable it again.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }.frame(minWidth: 520, minHeight: 600)
    }
}
#endif
