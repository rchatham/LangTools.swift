//
//  CollapsibleMessageView.swift
//  LangTools_Example
//
//  Created by Reid Chatham on 2/15/25.
//

import Foundation
import SwiftUI


struct CollapsibleMessageView<Message: ChatMessageInfo>: View {
    @ObservedObject var message: Message
    @Environment(\.colorScheme) var colorScheme
    @State private var isExpanded = false
    @Binding var parentIsExpanded: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Main message bubble
            Button(action: {
                if !message.childChatMessages.isEmpty {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        parentIsExpanded = false
                    }
                }
            }) {
                HStack {
                    if message.isUser { Spacer() }

                    VStack(alignment: .leading) {
                        HStack {
                            if !message.childChatMessages.isEmpty {
                                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 12))
                                    .foregroundColor(messageColor.opacity(0.7))
                            }

                            Text(message.text ?? "")
                                .font(.system(size: 16))
                                .foregroundColor(messageColor)
                        }
                        .padding(10)
                        .background(backgroundColor)
                        .cornerRadius(10)
                    }

                    if message.isAssistant { Spacer() }
                }
            }
            .buttonStyle(PlainButtonStyle())

            // Child messages
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(message.childChatMessages) { childMessage in
                        let binding = Binding<Bool?>(
                            get: { isExpanded },
                            set: { val in isExpanded = val ?? false })
                        CollapsibleMessageView(message: childMessage, parentIsExpanded: binding)
                            .padding(.leading, 16)
                    }
                }
                .padding(.top, 4)
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
                .overlay(
                    Rectangle()
                        .frame(width: 2)
                        .foregroundColor(Color.gray.opacity(0.3))
                        .padding(.leading, 7),
                    alignment: .leading
                )
            }
        }
    }

    private var messageColor: Color {
        if message.isAgentEvent {
            return .secondary
        }
        return message.isUser ? 
            (colorScheme == .dark ? .white : .black) : 
            .white
    }
    
    private var backgroundColor: Color {
        if message.isAgentEvent {
            return colorScheme == .dark ? 
                Color.gray.opacity(0.3) : 
                Color.gray.opacity(0.1)
        }
        return message.isUser ? 
            (colorScheme == .dark ? Color.gray.opacity(0.5) : .gray.opacity(0.2)) : 
            .blue
    }
}
