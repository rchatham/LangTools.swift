//
//  MessageComposerView.swift
//
//  Created by Reid Chatham on 4/2/23.
//

import SwiftUI
import CoreData

// MessageComposerView
struct MessageComposerView: View {
    @ObservedObject var viewModel: ViewModel
    @FocusState private var promptTextFieldIsActive
    
    var body: some View {
        HStack {
            TextField("Enter your prompt", text: $viewModel.input, axis: .vertical)
                .textFieldStyle(.automatic)
                .padding(EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 10))
                .foregroundColor(.primary)
                .lineLimit(5)
                .multilineTextAlignment(.leading)
                .focused($promptTextFieldIsActive)
                .submitLabel(.done)
                .onSubmit(submitButtonTapped)
            Button(action: submitButtonTapped) {
                Text("Submit")
                    .padding(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 20))
                    .foregroundColor(.accentColor)
            }
        }
//        .defaultFocus($promptTextFieldIsActive, true, priority: .automatic)
        .alert(isPresented: $viewModel.showAlert, content: {
            Alert(title: Text("Error"), message: Text(viewModel.errorMessage), dismissButton: .default(Text("OK")))
        })
        .enterAPIKeyAlert(
            isPresented: $viewModel.enterApiKey,
            apiKey: $viewModel.apiKey)
    }
    
    func submitButtonTapped() {
        viewModel.sendMessage()
        promptTextFieldIsActive = true
   }
}

extension MessageComposerView {
    // MessageComposerViewModel
    @MainActor class ViewModel: ObservableObject {
        @Published var input: String = ""

        @Published var showAlert: Bool = false
        @Published var errorMessage: String = ""
        @Published var enterApiKey: Bool = false
        @Published var apiKey: String = ""

        private var messageService: MessageService

        init(messageService: MessageService) {
            self.messageService = messageService
        }
        
        func sendMessage() {
            guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            // Send the message completion request
            Task { [input] in
                do { try await messageService.performMessageCompletionRequest(message: input, stream: true) }
                catch let error as LangToolchainError {
                    print("cannot handle request, probably a missing api key: \(error.localizedDescription)")
                    self.enterApiKey = true
                }
//                catch let error as NetworkClient.NetworkError.missingApiKey {
//                    self.enterApiKey = true
//                }
                catch {
                    print("Error sending message completion request: \(error)")
                    self.errorMessage = error.localizedDescription
                    self.showAlert = true
                }
            }

            // Clear the input field
            input = ""
        }
    }
}
