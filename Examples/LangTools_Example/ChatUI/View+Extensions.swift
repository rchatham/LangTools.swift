//
//  View+Extensions.swift
//  LangTools_Example
//
//  Created by Reid Chatham on 2/16/25.
//

import SwiftUI

extension View {
    func invalidInputAlert(isPresented: Binding<Bool>) -> some View {
        return alert(Text("Invalid Input"), isPresented: isPresented, actions: {
            Button("OK", role: .cancel, action: {})
        }, message: { Text("Please enter a valid prompt") })
    }
}
