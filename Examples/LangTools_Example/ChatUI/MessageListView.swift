//
//  MessageListView.swift
//
//  Created by Reid Chatham on 4/2/23.
//

import SwiftUI

struct MessageListView<MessageService: ChatMessageService>: View {
    @StateObject var viewModel: ViewModel

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                LazyVStack(alignment: .leading) {
                    ForEach(viewModel.messageService.chatMessages, id: \.uuid) { message in
                        CollapsibleMessageView(message: message)
                    }
                }
                .padding(16)
            }
            .onAppear {
                scrollToBottom(scrollProxy: scrollProxy)
                #if os(iOS)
                NotificationCenter.default.addObserver(
                    forName: UIResponder.keyboardDidShowNotification,
                    object: nil,
                    queue: .main
                ) { _ in
                    scrollToBottom(scrollProxy: scrollProxy)
                }
                #endif
            }
            .onDisappear {
                #if os(iOS)
                NotificationCenter.default.removeObserver(self)
                #endif
            }.onChange(of: viewModel.messageService.chatMessages.last?.text) { (_,_) in
                scrollToBottom(scrollProxy: scrollProxy)
            }
        }
    }

    func scrollToBottom(scrollProxy: ScrollViewProxy) {
        guard let last = viewModel.messageService.chatMessages.last else { return }
        withAnimation {
            scrollProxy.scrollTo(last, anchor: .bottom)
        }
    }
}

extension MessageListView {
    @MainActor class ViewModel: ObservableObject {
        var messageService: MessageService

        init(messageService: MessageService) {
            self.messageService = messageService
        }
    }
}
