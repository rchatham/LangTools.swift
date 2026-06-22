import Foundation
import LangTools

/// Minimal example implementation of LangTools' provider-neutral translation contract.
///
/// The example app does not currently expose a translation UI, so this provider is
/// intentionally deterministic and local. It exists to keep new LangTools provider
/// protocols represented in LangTools_Example and to give app code a concrete
/// compile-time integration point.
public struct ExampleTranslationProvider: TextTranslationProviding {
    public let providerID = LangToolsProviderID(rawValue: "example.echo.translation")
    public let displayName = "Example Echo Translation"
    public let capabilities = ProviderCapabilities(
        runsOnDevice: true,
        supportsStreamingPartials: false,
        supportsContinuousMode: false,
        supportsDualLanguageAutoDetect: false,
        requiresNetwork: false,
        requiresModelDownload: false
    )

    public init() {}

    public func prepare(sourceLanguageIdentifier: String, targetLanguageIdentifier: String) async throws {}

    public func translate(_ request: LangToolsTextTranslationRequest) async throws -> LangToolsTextTranslationResponse {
        LangToolsTextTranslationResponse(
            translatedText: "[\(request.targetLanguageIdentifier)] \(request.text)",
            detectedSourceLanguageIdentifier: request.sourceLanguageIdentifier
        )
    }
}
