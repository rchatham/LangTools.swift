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
                    .foregroundColor(viewModel.isMessageSending ? .red : .accentColor)
                    .padding(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 20))
            }
        }
        .alert(viewModel.alertInfo?.title ?? "///Missing title///", isPresented: $viewModel.showAlert, actions: {
            if let alertInfo = $viewModel.alertInfo.wrappedValue, let tf = alertInfo.textField, let bt = alertInfo.button {
                TextField(tf.label, text: tf.text)
                Button(bt.text, role: bt.role, action: { do { try bt.action(alertInfo) } catch { viewModel.handleError(error) } })
            }
            Button("Cancel", role: .cancel, action: {})
        }, message: {
            if let text = $viewModel.alertInfo.wrappedValue?.message { Text(text) }
        })
        .alert(isPresented: $viewModel.showError, content: {
            Alert(title: Text("Error"), message: Text($viewModel.alertInfo.wrappedValue?.title ?? ""), dismissButton: .default(Text("OK")))
        })
    }

    func submitButtonTapped() {
        if viewModel.isMessageSending { return }

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
        @Published var alertInfo: ChatAlertInfo?
        @Published var showError: Bool = false
        @Published var isMessageSending: Bool = false

        private var messageService: any ChatMessageService

        init(messageService: any ChatMessageService) {
            self.messageService = messageService
        }

        func sendMessage() async {
            guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            // Send the message completion request
            isMessageSending = true
            let sentText = input
            // Clear the input field
            Task { @MainActor in input = "" }
            do { try await messageService.performChatCompletionRequest(message: sentText, stream: true) }
            catch {
                handleError(error)
                Task { @MainActor in input = sentText }
            }
            isMessageSending = false
        }

        func handleError(_ error: any Error) {
            if let alertInfo = messageService.handleError(error: error) {
                self.alertInfo = alertInfo
                self.showAlert = true
            } else {
                self.alertInfo = ChatAlertInfo(title: "Error!", textField: nil , button: nil, message: "Error sending message completion request: \(error)")
                self.showError = true
            }
        }
    }
}
