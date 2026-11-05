import Agents
import Chat
import LangTools

/// Ordinary-import library consumer. References are typechecked, never invoked.
public enum MessageServiceDependenciesSmoke {
    @MainActor
    public static func compileInitializers() {
        let legacy: (NetworkClientProtocol, [any Agent]?, [Tool]?, ToolSettings) -> MessageService =
            MessageService.init(networkClient:agents:tools:toolSettings:)
        let owned: (NetworkClientProtocol, [any Agent]?, [Tool]?, MessageService.Dependencies) -> MessageService =
            MessageService.init(networkClient:agents:tools:dependencies:)
        // Compile actual legacy defaults too, without constructing any service.
        let defaults: () -> MessageService = { MessageService() }
        let clientOnly: (NetworkClientProtocol) -> MessageService = { MessageService(networkClient: $0) }
        let dependencies = MessageService.Dependencies(
            selectedModel: { .openAI(.gpt4o_mini) },
            conversationSettings: { ChatConversationSettings(systemPrompt: "memory") },
            keepsToolCallsInHistory: { false },
            maxToolIterations: { 0 },
            enabledTools: { nil },
            toolConfigurations: { [] }
        )
        _ = (legacy, owned, defaults, clientOnly, dependencies)
    }
}
