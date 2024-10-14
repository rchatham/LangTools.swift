//
//  MessageListView.swift
//
//  Created by Reid Chatham on 4/2/23.
//

import SwiftUI

struct MessageListView: View {
    @StateObject var viewModel: ViewModel

    var body: some View {
//        @ObservedObject var viewModel = viewModel
        ScrollViewReader { scrollProxy in
            ScrollView {
                LazyVStack(alignment: .leading) {
                    ForEach(viewModel.messageService.messages, id: \.self) { message in
                        if !(message.text?.isEmpty ?? true), message.role != .tool { MessageView(message: message) }
                    }
                }
                .padding(16)
            }
            .onAppear {
                scrollToBottom(scrollProxy: scrollProxy)
                #if os(iOS)
                    NotificationCenter.default.addObserver(forName: UIResponder.keyboardDidShowNotification, object: nil, queue: .main) { notification in
                        scrollToBottom(scrollProxy: scrollProxy)
                    }
                #endif
            }
            .onDisappear {
                #if os(iOS)
                    NotificationCenter.default.removeObserver(self)
                #endif
            }
            .onChange(of: viewModel.messageService.messages.last?.text) {
                scrollToBottom(scrollProxy: scrollProxy)
            }
        }
    }

    func scrollToBottom(scrollProxy proxy: ScrollViewProxy) {
        guard let last = viewModel.messageService.messages.last else { return }
        withAnimation {
            proxy.scrollTo(last, anchor: UnitPoint(x: UnitPoint.bottom.x, y: 0.95))
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

//struct MessageListView_Previews: PreviewProvider {
//    static var previews: some View {
//        MessageListView(viewModel: .init(messageService: .init()))
//    }
//}
