import SwiftUI
#if os(iOS)
import UIKit
#endif

private struct MobileHelperPairingPresentation: ViewModifier {
    @ObservedObject private var coordinator: MobileHelperPairingCoordinator
    private let brandingTitle: String

    init(coordinator: MobileHelperPairingCoordinator, brandingTitle: String) {
        self.coordinator = coordinator
        self.brandingTitle = brandingTitle
    }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(get: { coordinator.pendingPairing != nil }, set: {
                if !$0, coordinator.pendingPairing != nil { coordinator.cancel() }
            })) {
                if let pairing = coordinator.pendingPairing {
                    let generation = coordinator.pendingGeneration
                    NavigationStack {
                        VStack(alignment: .leading, spacing: 20) {
                            Label("Pair with \(pairing.name)?", systemImage: "desktopcomputer")
                                .font(.title2.bold())
                            Text(pairing.endpoint.absoluteString).font(.callout).foregroundStyle(.secondary)
                            Text("Allow this Mac to provide Ollama models and process your chats. Confirm only if you scanned this QR from your trusted Mac.")
                            Label("Requested capability: Ollama", systemImage: "checkmark.shield")
                            Text("Encrypted connection pinned to this helper's certificate. No account, filesystem, or command access is granted.")
                                .font(.footnote).foregroundStyle(.secondary)
                            Button("Pair and Use Helper") { coordinator.confirm(pairing, generation: generation, deviceName: deviceName) }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("mobile-helper-confirm")
                            Button("Cancel", role: .cancel) { coordinator.cancel() }
                            Spacer()
                        }
                        .padding(24)
                        .navigationTitle(brandingTitle)
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
        modifier(MobileHelperPairingPresentation(coordinator: .shared, brandingTitle: "Connect LangToolsHelper"))
    }

    public func mobileHelperPairingPresentation(coordinator: MobileHelperPairingCoordinator,
                                               brandingTitle: String) -> some View {
        modifier(MobileHelperPairingPresentation(coordinator: coordinator, brandingTitle: brandingTitle))
    }
}
