//
//  Model.swift
//  LangTools_Example
//
//  Created by Reid Chatham on 9/29/24.
//
import Foundation
import OpenAI
import Anthropic


enum Model: RawRepresentable, Hashable {
    typealias RawValue = String
    case openAI(OpenAI.Model)
    case anthropic(Anthropic.Model)

    init?(rawValue: String) {
        if let model = OpenAI.Model(rawValue: rawValue) { self = .openAI(model) }
        else if let model = Anthropic.Model(rawValue: rawValue) { self = .anthropic(model) }
        else { return nil }
    }

    var rawValue: String {
        switch self {
        case .openAI(let model): return model.rawValue
        case .anthropic(let model): return model.rawValue
        }
    }

    static var allCases: [String] = OpenAI.Model.allCases.map{$0.rawValue} + Anthropic.Model.allCases.map{$0.rawValue}

    func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue)
    }
}
