//
//  LangTools_ExampleApp.swift
//  LangTools_Example
//
//  Created by Reid Chatham on 9/23/24.
//

import SwiftUI

@main
struct LangTools_ExampleApp: App {
    var body: some Scene {
        WindowGroup {
            ChatView(viewModel: .init(messageService: .init()))
        }
    }
}
