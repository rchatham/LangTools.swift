//
//  View+Extensions.swift
//
//  Created by Reid Chatham on 4/1/23.
//

import SwiftUI

extension View {
    func invalidInputAlert(isPresented: Binding<Bool>) -> some View {
        return alert(Text("Invalid Input"), isPresented: isPresented, actions: {
            Button("OK", role: .cancel, action: {})
        }, message: { Text("Please enter a valid prompt") })
    }

    func enterAPIKeyAlert(isPresented: Binding<Bool>, apiKey: Binding<String>) -> some View {
        let llmInfo: (String, LLMAPIService) = {
            switch UserDefaults.model {
            case .anthropic(_): return ("Anthropic", .anthropic)
            case .openAI(_): return ("OpenAI", .openAI)
            case .xAI(_): return ("xAI", .xAI)
            case .gemini(_): return ("Gemini", .gemini)
            }
        }()
        return alert("Enter API Key", isPresented: isPresented, actions: {
            TextField("API Key", text: apiKey)
            Button("Save for \(llmInfo.0)", action: {
                do { try NetworkClient.shared.updateApiKey(apiKey.wrappedValue, for: llmInfo.1)}
                catch { if case .emptyApiKey = error as? NetworkClient.NetworkError { print("Empty api key") }}
            })
            Button("Cancel", role: .cancel, action: {})
        }, message: { Text("Please enter your \(llmInfo.0) API key.") })
    }
}

struct EmptyLabel: View {
    var body: some View {
        Label(title: { Text("") }, icon: {Image(systemName: "")})
    }
}
