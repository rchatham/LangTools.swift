import Chat
import SwiftUI

/// Ordinary-import compile coverage only. This function is never invoked.
public enum AccessPromptLifecycleSmoke {
    public typealias SaveKey = (String, APIService) throws -> Void
    public typealias RemoveKey = (APIService) throws -> Void
    public typealias AccountAction = (AccountLoginProvider) async throws -> Void
    public typealias HelperAction = () async throws -> Void

    @MainActor
    public static func compileInitializerReferences() {
        let legacy: (ProviderAccessManager, @escaping SaveKey, @escaping RemoveKey,
            @escaping AccountAction, @escaping AccountAction, @escaping HelperAction,
            @escaping HelperAction) -> AccessPromptContext = AccessPromptContext.init(
                accessManager:saveAPIKey:removeAPIKey:connectAccount:disconnectAccount:
                connectCodexHelper:disconnectCodexHelper:)
        let injected: (ProviderAccessManager, @escaping SaveKey, @escaping RemoveKey,
            @escaping AccountAction, @escaping AccountAction, @escaping HelperAction,
            @escaping HelperAction, Binding<Model>, AuthPresentationCoordinator,
            AccountLoginCoordinator) -> AccessPromptContext = AccessPromptContext.init(
                accessManager:saveAPIKey:removeAPIKey:connectAccount:disconnectAccount:
                connectCodexHelper:disconnectCodexHelper:selectedModelBinding:
                presentationCoordinator:loginCoordinator:)
        let presentation: () -> AuthPresentationCoordinator = AuthPresentationCoordinator.init
        let login: () -> AccountLoginCoordinator = AccountLoginCoordinator.init
        _ = (legacy, injected, presentation, login)
    }
}
