//
//  UserDefaults+Extensions.swift
//  LangTools_Example
//
//  Created by Reid Chatham on 5/15/25.
//

import SwiftUI


// UserDefaults extension for setting and getting the device token
extension UserDefaults {
    private static let serperApiKeyKey = "serperApiKey"

    static var serperApiKey: String? {
        get { standard.string(forKey: serperApiKeyKey) }
        set { standard.setValue(newValue, forKey: serperApiKeyKey) }
    }
}

