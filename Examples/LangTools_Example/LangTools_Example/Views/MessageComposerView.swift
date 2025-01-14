//
//  MessageComposerView.swift
//
//  Created by Reid Chatham on 4/2/23.
//

import SwiftUI
import CoreData

struct MessageComposerView: View {
    @ObservedObject var viewModel: ViewModel
    @FocusState var promptTextFieldIsActive: Bool

    var body: some View {
        HStack {
            TextField("Enter your prompt", text: $viewModel.input, axis: .vertical)
                .textFieldStyle(.automatic)
                .padding(EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 10))
                .foregroundColor(.primary)
                .lineLimit(5)
                .multilineTextAlignment(.leading)
                .submitLabel(.done)
                .onSubmit(submitButtonTapped)
                .focused($promptTextFieldIsActive)
            Button(action: submitButtonTapped) {
                Text("Submit")
                    .foregroundColor(viewModel.messageIsSending ? .red : .accentColor)
                    .padding(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 20))
            }
        }
        .alert(isPresented: $viewModel.showAlert, content: {
            Alert(title: Text("Error"), message: Text(viewModel.errorMessage), dismissButton: .default(Text("OK")))
        })
        .enterAPIKeyAlert(
            isPresented: $viewModel.enterApiKey,
            apiKey: $viewModel.apiKey)
    }
    
    func submitButtonTapped() {
        if viewModel.messageIsSending { return }

        Task {
            await viewModel.sendMessage()
            promptTextFieldIsActive = true
        }
   }
}

extension MessageComposerView {
    @MainActor class ViewModel: ObservableObject {
        @Published var input: String = ""

        @Published var showAlert: Bool = false
        @Published var errorMessage: String = ""
        @Published var enterApiKey: Bool = false
        @Published var apiKey: String = ""
        @Published var messageIsSending: Bool = false

        private var messageService: MessageService

        init(messageService: MessageService) {
            self.messageService = messageService
        }
        
        func sendMessage() async {
            guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            // Send the message completion request
            messageIsSending = true
            do { try await messageService.performMessageCompletionRequest(message: input, stream: true) }
            catch let error as LangToolchainError {
                print("cannot handle request, probably a missing api key: \(error.localizedDescription)")
                self.enterApiKey = true
            }
            catch {
                print("Error sending message completion request: \(error)")
                self.errorMessage = error.localizedDescription
                self.showAlert = true
            }
            messageIsSending = false

            // Clear the input field
            input = ""
        }
    }
}
