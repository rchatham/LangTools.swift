//
//  ChatView.swift
//
//  Created by Reid Chatham on 1/20/23.
//

import SwiftUI
import CoreData
import Combine

public struct ChatView<MessageService: ChatMessageService, SettingsView: View>: View {
    @ObservedObject var viewModel: ViewModel

    public init(messageService: MessageService, settingsView: (() -> SettingsView)?) {
        viewModel = ViewModel(messageService: messageService, settingsView: settingsView)
    }

    public init(viewModel: ViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationStack {
            VStack {
                messageList
                messageComposerView
                    .invalidInputAlert(isPresented: $viewModel.showAlert)
            }
            .navigationTitle("LangTools.swift")
            .toolbar {
                #if DEBUG
                NavigationLink(destination: viewModel.settingsView()) {
                    Image(systemName: "gear")
                }
                #endif
            }
        }
    }

    @ViewBuilder
    var messageList: some View {
        MessageListView(viewModel: viewModel.messageListViewModel())
    }

    @ViewBuilder
    var messageComposerView: some View {
        MessageComposerView(viewModel: viewModel.messageComposerViewModel())
    }
}

extension ChatView {
    @MainActor public class ViewModel: ObservableObject {
        @Published var input = ""
        @Published var showAlert = false
        private let messageService: MessageService
        private var _settingView: (() -> SettingsView)?

        public init(messageService: MessageService, settingsView: (() -> SettingsView)?) {
            self.messageService = messageService
            _settingView = settingsView
        }

        func delete(id: UUID) {
            messageService.deleteMessage(id: id)
        }

        func settingsView() -> (some View)? {
            return _settingView?()
        }
        
        func messageComposerViewModel() -> MessageComposerView.ViewModel {
            return MessageComposerView.ViewModel(messageService: messageService)
        }

        func messageListViewModel() -> MessageListView<MessageService>.ViewModel {
            return MessageListView.ViewModel(messageService: messageService)
        }
    }
}
