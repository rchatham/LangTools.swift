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

enum Model: Codable, RawRepresentable, Hashable, CaseIterable, Identifiable {
    typealias RawValue = String
    case openAI(OpenAI.Model)
    case anthropic(Anthropic.Model)
    case xAI(XAIModel)

    init?(rawValue: String) {
        if let modelID = OpenAIModel.ModelID(rawValue: rawValue) { self = .openAI(modelID.openAIModel) }
        else if let model = Anthropic.Model(rawValue: rawValue) { self = .anthropic(model) }
        else if let model = XAIModel(rawValue: rawValue) { self = .xAI(model) }
        else { return nil }
    }

    var rawValue: String {
        switch self {
        case .openAI(let model): return model.id
        case .anthropic(let model): return model.rawValue
        case .xAI(let model): return model.rawValue
        }
    }

    var id: String { rawValue }

    static var allCases: [Model] { OpenAI.Model.allCases.map { .openAI($0) } + Anthropic.Model.allCases.map { .anthropic($0) } + XAI.Model.allCases.map { .xAI($0) } }

    func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue)
    }
}
