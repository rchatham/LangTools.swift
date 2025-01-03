//
//  ChatSettingsView.swift
//
//  Created by Reid Chatham on 2/13/23.
//

import SwiftUI

struct ChatSettingsView: View {
    @StateObject var viewModel: ViewModel

    var body: some View {
        Form {
            Picker("AI Model", selection: $viewModel.model) {
                ForEach(Model.chatModels, id: \.self) { model in
                    Text(model.rawValue).tag(model.rawValue)
                }
            }
            .pickerStyle(.menu)

            Section(header: Text("Model Settings")) {
                Stepper("Max Tokens: \(viewModel.maxTokens)", value: $viewModel.maxTokens, in: 1...1000)
                HStack {
                    Text("Temperature:")
                    Slider(value: $viewModel.temperature, in: 0...1, step: 0.01)
                }
            }
            Button("Save Settings") { viewModel.saveSettings()}
            Button("Update API Key") { viewModel.enterApiKey = true}
        }
        .navigationTitle("Settings")
        .onAppear { viewModel.loadSettings()}
        .onDisappear { viewModel.saveSettings()}
        .enterAPIKeyAlert(isPresented: $viewModel.enterApiKey, apiKey: $viewModel.apiKey)
    }
}

extension ChatSettingsView {
    @MainActor class ViewModel: ObservableObject {
        @Published var apiKey = ""
        @Published var enterApiKey = false

        @Published var model: Model = UserDefaults.model
        @Published var maxTokens = UserDefaults.maxTokens
        @Published var temperature = UserDefaults.temperature
        @Published var deviceToken = UserDefaults.deviceToken

        func loadSettings() {
            model = UserDefaults.model
            maxTokens = UserDefaults.maxTokens
            temperature = UserDefaults.temperature
        }

        func saveSettings() {
            UserDefaults.model = model
            UserDefaults.maxTokens = maxTokens
            UserDefaults.temperature = temperature
        }
    }
}

//struct ChatSettingsView_Previews: PreviewProvider {
//    static var previews: some View {
//        ChatSettingsView(viewModel: ChatSettingsView.ViewModel())
//    }
//}
