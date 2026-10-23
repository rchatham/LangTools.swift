import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Capability-specific consent also used by presentation-copy regression tests.
enum MobileHelperPairingConsent {
    static func detail(capabilities: [String]) -> String {
        var details = ["Encrypted connection pinned to this helper's certificate."]
        if capabilities.contains("codex") {
            details.append("Codex account chat executes on your trusted Mac with its inherited native runtime tool permissions, including filesystem and command access. There is no per-device filesystem sandbox.")
        }
        if capabilities.contains("claude") {
            details.append("Claude external backend account credentials and chats transit your trusted Mac. This is not an API-key provider proxy.")
        }
        if capabilities == ["ollama"] {
            details.append("Ollama only: no account, filesystem, or command access is granted.")
        }
        return details.joined(separator: " ")
    }
}

private struct MobileHelperPairingPresentation: ViewModifier {
    @ObservedObject private var coordinator = MobileHelperPairingCoordinator.shared

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(get: { coordinator.pendingPairing != nil }, set: {
                if !$0, coordinator.pendingPairing != nil { coordinator.cancel() }
            })) {
                if let pairing = coordinator.pendingPairing {
                    let capabilities = (try? MobileHelperPairingScope.capabilities(pairing)) ?? []
                    let generation = coordinator.pendingGeneration
                    NavigationStack {
                        VStack(alignment: .leading, spacing: 20) {
                            Label("Pair with \(pairing.name)?", systemImage: "desktopcomputer")
                                .font(.title2.bold())
                            Text(pairing.endpoint.absoluteString).font(.callout).foregroundStyle(.secondary)
                            Text("Allow this Mac to provide the listed services and process chats routed to it. Confirm only if you scanned this QR from your trusted Mac. Account transports remain an explicit choice in settings.")
                            Label("Requested capabilities: \(capabilities.joined(separator: ", "))", systemImage: "checkmark.shield")
                            Text(MobileHelperPairingConsent.detail(capabilities: capabilities))
                                .font(.footnote).foregroundStyle(.secondary)
                            Button(capabilities.contains("ollama") ? "Pair and Use for Ollama" : "Pair Helper") { coordinator.confirm(pairing, generation: generation, deviceName: deviceName) }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("mobile-helper-confirm")
                            Button("Cancel", role: .cancel) { coordinator.cancel() }
                            Spacer()
                        }
                        .padding(24)
                        .navigationTitle("Connect LangToolsHelper")
                        #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                    }
                    .frame(minWidth: 300, minHeight: 400)
                }
            }
            .overlay(alignment: .top) {
                if coordinator.isPairing {
                    HStack {
                        ProgressView()
                        Text("Verifying helper identity…")
                        Button("Cancel", role: .cancel) { coordinator.cancel() }
                    }
                    .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .alert("Helper Pairing Failed", isPresented: Binding(get: { coordinator.errorMessage != nil }, set: {
                if !$0 { coordinator.dismissError() }
            })) {
                Button("OK", role: .cancel) { coordinator.dismissError() }
            } message: { Text(coordinator.errorMessage ?? "") }
    }

    private var deviceName: String {
        #if os(iOS)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? "LangTools device"
        #endif
    }
}

extension View {
    public func mobileHelperPairingPresentation() -> some View {
        modifier(MobileHelperPairingPresentation())
    }
}
