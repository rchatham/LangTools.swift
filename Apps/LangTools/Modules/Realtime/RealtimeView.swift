//
//  RealtimeView.swift
//  LangTools_Example
//
//  Live voice conversation with the OpenAI Realtime API. The screen itself
//  is ChatUI's RealtimeConversationView; this view owns the session view
//  model, so each presentation starts a fresh session.
//

import SwiftUI
import ChatUI

public struct RealtimeView: View {
    @StateObject private var viewModel: RealtimeSessionViewModel

    public init(apiKeyProvider: @escaping () -> String?) {
        _viewModel = StateObject(wrappedValue: RealtimeSessionViewModel(apiKeyProvider: apiKeyProvider))
    }

    public var body: some View {
        RealtimeConversationView(handler: viewModel, title: "Realtime Voice")
    }
}
