//
//  Message+ChatUI.swift
//
//  ChatUI conformance for `Message`. It lives in `Chat` so library types such
//  as `ChatHistory.ChatSession` can expose `[Message]` to `ChatView` without
//  every host app declaring the same retroactive conformance.
//

import Foundation
import ChatUI

extension Message: ChatMessageInfo {
    public var parentMessage: Message? { parent }
    public var childChatMessages: [Message] { childMessages }
}
