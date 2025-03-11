//
//  ChatSettingsView.swift
//
//  Created by Reid Chatham on 2/13/23.
//

import SwiftUI

public struct ChatSettingsView: View {
    @ObservedObject public var viewModel: ViewModel
    @State private var isEditingSystemMessage = false

    public init(viewModel: ViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Form {
            Section(header: Text("Active Model")) {
                Picker("Chat Models", selection: $viewModel.model) {
                    ForEach(Model.chatModels, id: \.self) { model in
                        Text(model.rawValue).tag(model.rawValue)
                    }
                }
                .pickerStyle(.menu)
            }

            Section(header: Text("System Message")) {
                HStack {
                    Text(viewModel.systemMessage)
                        .lineLimit(3)
                        .truncationMode(.tail)
                    Spacer()
                    Button("Edit") {
                        isEditingSystemMessage = true
                    }
                }
            }

            Button("Save Settings") { viewModel.saveSettings() }
            Button("Update API Key") { viewModel.enterApiKey = true }
            Button("Clear messages", role: .destructive) {
                viewModel.clearMessages()
            }
        }
        .navigationTitle("Settings")
        .onAppear { viewModel.loadSettings() }
        .onDisappear { viewModel.saveSettings() }
        .sheet(isPresented: $isEditingSystemMessage) {
            SystemMessageEditor(systemMessage: $viewModel.systemMessage)
        }
    }
}

extension ChatSettingsView {
    @MainActor public class ViewModel: ObservableObject {
        @Published var apiKey = ""
        @Published var enterApiKey = false
        @Published var model: Model = UserDefaults.model
        @Published var maxTokens = UserDefaults.maxTokens
        @Published var temperature = UserDefaults.temperature
        @Published var deviceToken = UserDefaults.deviceToken
        @Published var systemMessage = UserDefaults.systemMessage

        let clearMessages: () -> Void

        public init(clearMessages: @escaping () -> Void) {
            self.clearMessages = clearMessages
        }

        func loadSettings() {
            model = UserDefaults.model
            maxTokens = UserDefaults.maxTokens
            temperature = UserDefaults.temperature
            systemMessage = UserDefaults.systemMessage
        }

        func saveSettings() {
            UserDefaults.model = model
            UserDefaults.maxTokens = maxTokens
            UserDefaults.temperature = temperature
            UserDefaults.systemMessage = systemMessage
        }
    }
}

struct SystemMessageEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var systemMessage: String
    @State private var editedMessage: String = ""

    var body: some View {
        NavigationView {
            VStack {
                TextEditor(text: $editedMessage)
                    .font(.body)
                    .padding()
                    .frame(maxHeight: .infinity)
            }
            .navigationTitle("Edit System Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        systemMessage = editedMessage
                        dismiss()
                    }
                }
            }
            .onAppear {
                editedMessage = systemMessage
            }
        }
    }
}
