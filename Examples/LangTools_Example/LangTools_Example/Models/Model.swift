//
//  Model.swift
//  LangTools_Example
//
//  Created by Reid Chatham on 9/29/24.
//
import Foundation
import OpenAI
import Anthropic
import XAI
import Gemini

enum Model: Codable, RawRepresentable, Hashable, CaseIterable, Identifiable, Equatable {
    typealias RawValue = String
    case openAI(OpenAI.Model)
    case anthropic(Anthropic.Model)
    case xAI(XAI.Model)
    case gemini(Gemini.Model)

    init?(rawValue: String) {
        if let model = OpenAI.Model(rawValue: rawValue) { self = .openAI(model) }
        else if let model = Anthropic.Model(rawValue: rawValue) { self = .anthropic(model) }
        else if let model = XAI.Model(rawValue: rawValue) { self = .xAI(model) }
        else if let model = Gemini.Model(rawValue: rawValue) { self = .gemini(model) }
        else { return nil }
    }

    var rawValue: String {
        switch self {
        case .openAI(let model): return model.rawValue
        case .anthropic(let model): return model.rawValue
        case .xAI(let model): return model.rawValue
        case .gemini(let model): return model.rawValue
        }
    }

    var id: String { rawValue }

    static let _modelInitilizer: Void = {
        _ = XAI.Model.allCases.map { $0.openAIModel }
        _ = Gemini.Model.allCases.map { $0.openAIModel }
    }()

    static var allCases: [Model] {
        _ = _modelInitilizer
        return OpenAI.Model.allCases.map { .openAI($0) } + Anthropic.Model.allCases.map { .anthropic($0) }
    }

    static var chatModels: [Model] {
        _ = _modelInitilizer
        return OpenAI.Model.chatModels.map { .openAI($0) } + Anthropic.Model.allCases.map { .anthropic($0) }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue)
    }
}
