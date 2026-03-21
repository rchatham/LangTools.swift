//
//  View+Extensions.swift
//  App
//
//  Created by Reid Chatham on 3/2/25.
//

import SwiftUI

extension View {
    // Unified API key entry alert that works with any APIService
    func enterAPIKeyAlert(isPresented: Binding<Bool>, apiKey: Binding<String>, service: APIService) -> some View {
        let serviceName = service.displayName
        let description = service.description
        
        return alert("Enter \(serviceName) API Key", isPresented: isPresented, actions: {
            TextField("API Key", text: apiKey)
            Button("Save for \(serviceName)", action: {
                if !apiKey.wrappedValue.isEmpty {
                    if service == .serper {
                        // Save Serper API key to UserDefaults
                        UserDefaults.serperApiKey = apiKey.wrappedValue
                        // Also save to keychain for consistency
                        KeychainService().saveApiKey(apiKey: apiKey.wrappedValue, for: service)
                    } else {
                        // Save LLM API key using NetworkClient
                        do { try NetworkClient.shared.updateApiKey(apiKey.wrappedValue, for: service) }
                        catch { if case .emptyApiKey = error as? NetworkClient.NetworkError { print("Empty api key") } }
                    }
                }
            })
            Button("Cancel", role: .cancel, action: {})
        }, message: { Text(description) })
    }
    
    // Convenience method for LLM API keys (uses the current model)
    func enterAPIKeyAlert(isPresented: Binding<Bool>, apiKey: Binding<String>) -> some View {
        let service: APIService = {
            switch UserDefaults.model {
            case .anthropic: return .anthropic
            case .openAI: return .openAI
            case .xAI: return .xAI
            case .gemini: return .gemini
            case .ollama: return .ollama
            }
        }()
        return enterAPIKeyAlert(isPresented: isPresented, apiKey: apiKey, service: service)
    }
    
    // Convenience method for Serper API key
    func enterSerperAPIKeyAlert(isPresented: Binding<Bool>, apiKey: Binding<String>) -> some View {
        return enterAPIKeyAlert(isPresented: isPresented, apiKey: apiKey, service: .serper)
    }
}

// Extension to provide friendly display names and descriptions for APIService
extension APIService {
    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openAI: return "OpenAI"
        case .xAI: return "xAI"
        case .gemini: return "Gemini"
        case .ollama: return "Ollama"
        case .serper: return "Serper"
        }
    }
    
    var description: String {
        switch self {
        case .serper:
            return "Please enter your Serper API key for web search capabilities."
        default:
            return "Please enter your \(displayName) API key."
        }
    }
}

