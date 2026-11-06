import Foundation
import Ollama

/// Stores the hosted catalog independently of endpoint-scoped local models.
/// Production uses the existing standard-defaults key and string-array schema.
public struct OllamaCloudModelStore {
    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    public func cachedModels() -> [Ollama.Model] {
        let cachedModels = userDefaults.stringArray(forKey: "ollamaCloudModels")?
            .compactMap(Model.normalizedOllamaCloudModelID)
            .compactMap(Ollama.Model.init(rawValue:)) ?? []
        if !cachedModels.isEmpty { return cachedModels }
        guard let model = Ollama.Model(rawValue: Model.defaultOllamaCloudModelID) else { return [] }
        return [model]
    }

    public func updateCachedModels(_ models: [Ollama.Model]) {
        var seen = Set<String>()
        let modelNames = models.compactMap { model -> String? in
            guard let modelID = Model.normalizedOllamaCloudModelID(model.rawValue),
                  seen.insert(modelID).inserted else { return nil }
            return modelID
        }
        userDefaults.set(modelNames, forKey: "ollamaCloudModels")
    }
}
