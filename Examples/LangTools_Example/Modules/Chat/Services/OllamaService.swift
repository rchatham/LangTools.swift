//
//  OllamaService.swift
//
//  Created by Reid Chatham on 2/25/25.
//

import Combine
import Foundation
import LangTools
import Ollama

public class OllamaService: ObservableObject {
    public static let shared = OllamaService()

    @Published var availableModels: [Ollama.Model] = []
    @Published var runningModels: [Ollama.ListRunningModelsResponse.RunningModelInfo] = []
    @Published var isLoading = false
    @Published var error: Error?

    private var ollama = Ollama()

    public func refreshModels() {
        isLoading = true
        error = nil

        Task {
            do {
                let response = try await ollama.listModels()
                let models = response.models.map { Ollama.Model(rawValue: $0.name)! }

                let runningResponse = try? await ollama.listRunningModels()
                let runningModels = runningResponse?.models ?? []

                await MainActor.run {
                    self.availableModels = models
                    self.runningModels = runningModels
                    self.isLoading = false

                    // Update the cached models in UserDefaults
                    Model.updateCachedOllamaModels(models)
                }
            } catch {
                await MainActor.run {
                    self.error = error
                    self.isLoading = false
                }
            }
        }
    }

    func pullModel(_ modelName: String, progressHandler: @escaping (Double) -> Void) async throws {
        for try await response in ollama.streamPullModel(modelName) {
            if let total = response.total, let completed = response.completed {
                let progress = Double(completed) / Double(total)
                await MainActor.run {
                    progressHandler(progress)
                }
            }
        }

        // Refresh the models list after pulling
        await MainActor.run {
            self.refreshModels()
        }
    }

    func loadModel(_ model: Ollama.Model) async throws {
        // This will load the model into memory by sending a simple request
        _ = try await ollama.chat(
            model: model,
            messages: [Ollama.Message(role: .user, content: "Hello")]
        )

        await MainActor.run {
            self.refreshModels()
        }
    }

    func updateBaseUrl(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        ollama.configuration.baseURL = url
    }

    func checkConnection() async throws -> Bool {
        do {
            // Attempt to get Ollama version as a quick connection test
            _ = try await self.ollama.version()
            return true
        } catch {
            return false
        }
    }
}
