import Chat

/// Ordinary-import, library-only API references. Build this file; never invoke it.
public enum ErrorPublicationSmoke {
    @MainActor
    public static func compileReferences(service: OllamaService) {
        let begin: (Bool) -> OllamaService.ErrorPublicationClaim = service.beginErrorPublication(clearError:)
        let current: (OllamaService.ErrorPublicationClaim) -> Bool = service.isCurrentErrorPublication
        let publish: (Error?, OllamaService.ErrorPublicationClaim) -> Bool = service.publishError(_:for:)
        let invalidate: () -> Void = service.invalidateErrorPublications
        let publisher = service.$error
        // Preserve the public writable property as well as its projected publisher.
        let assign: (Error?) -> Void = { service.error = $0 }
        _ = (begin, current, publish, invalidate, publisher, assign)
    }
}
