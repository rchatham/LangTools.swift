/// Resolves app defaults only when the legacy sheet is actually presented.
/// Injected presentation never looks up the global Ollama service.
@MainActor
enum OllamaSettingsPresentation {
    case legacy
    case injected(OllamaService)

    func makeView() -> OllamaSettingsView {
        switch self {
        case .legacy:
            return OllamaSettingsView()
        case .injected(let service):
            return OllamaSettingsView(ollamaService: service)
        }
    }
}
