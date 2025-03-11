//
//  MessageView.swift
//
//  Created by Reid Chatham on 4/2/23.
//

import SwiftUI

struct MessageView<Message: ChatMessageInfo>: View {
    @ObservedObject var message: Message
    @Environment(\.colorScheme) var colorScheme // Get the current color scheme
    
    var body: some View {
        HStack {
            if message.isUser { Spacer() }
            VStack(alignment: .leading) {
                Text(message.text ?? "")
                    .font(.system(size: 18)) // Adjust the font size if necessary
                    .foregroundColor(messageColor) // Set text color based on message type
                    .padding(10) // Add padding around the text
                    .background(backgroundColor) // Set background color for message bubble
                    .cornerRadius(message.isAgentEvent ? 0 : 10) // Add rounded corners to the message bubble
            }
            if message.isAssistant { Spacer()}
        }
        .padding(.horizontal, 10) // Add horizontal padding to HStack
    }

    private var messageColor: Color {
        if message.isAgentEvent {
            return .secondary
        }
        return message.isUser ? (colorScheme == .dark ? .white : .black) : .white
    }

    private var backgroundColor: Color {
        if message.isAgentEvent {
            return colorScheme == .dark ? Color.gray.opacity(0.3) : Color.gray.opacity(0.1)
        }
        return message.isUser ?
            (colorScheme == .dark ? Color.gray.opacity(0.5) : .gray.opacity(0.2)) :
            .blue
    }
}
