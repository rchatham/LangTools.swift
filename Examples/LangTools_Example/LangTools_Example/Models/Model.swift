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
    case xAI(XAIModel)

    init?(rawValue: String) {
        if let model = OpenAIModel(model: rawValue) { self = .openAI(model) }
        else if let model = Anthropic.Model(rawValue: rawValue) { self = .anthropic(model) }
        else if let model = XAIModel(rawValue: rawValue) { self = .xAI(model) }
        else { return nil }
    }

    var rawValue: String {
        switch self {
        case .openAI(let model): return model.modelID
        case .anthropic(let model): return model.rawValue
        case .xAI(let model): return model.rawValue
        }
    }

    static var allCases: [String] { OpenAIModel.allCases.map { $0.modelID } + Anthropic.Model.allCases.map { $0.rawValue } }

    func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue)
    }
}

enum XAIModel: String, CaseIterable {
    case grok = "grok-2-1212"
    case grokVision = "grok-2-vision-1212"

    var openAIModel: OpenAIModel { OpenAIModel(customModelID: rawValue) }
}
