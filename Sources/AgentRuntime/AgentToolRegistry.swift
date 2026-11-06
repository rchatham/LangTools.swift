//
//  AgentToolRegistry.swift
//  AgentRuntime
//
//  Tool callbacks are Swift closures and cannot travel inside a spec, so a spec lists
//  tool names and the runtime looks them up here. A runtime binary decides which tools
//  exist by what it registers.
//

import Foundation
import LangTools

public struct AgentToolRegistry {
    private var tools: [String: any LangToolsTool] = [:]

    public init(_ tools: [any LangToolsTool] = []) {
        for tool in tools { register(tool) }
    }

    /// Replaces any tool with the same name.
    public mutating func register(_ tool: any LangToolsTool) {
        tools[tool.name] = tool
    }

    public func tool(named name: String) -> (any LangToolsTool)? { tools[name] }

    public var names: [String] { tools.keys.sorted() }

    public var all: [any LangToolsTool] { names.compactMap { tools[$0] } }

    /// The named tools in order, or an error naming every one that is missing.
    func resolve(_ names: [String]) throws -> [any LangToolsTool] {
        let missing = names.filter { tools[$0] == nil }
        guard missing.isEmpty else { throw AgentRuntimeError.unknownTools(missing, available: self.names) }
        return names.compactMap { tools[$0] }
    }
}

extension AgentToolRegistry {
    /// Tools with no side effects outside the process, safe to include in any runtime.
    public static var builtIn: AgentToolRegistry { AgentToolRegistry([BuiltInTools.currentTime]) }
}

public enum BuiltInTools {
    /// Returns the current time as ISO 8601, optionally in a named time zone.
    public static var currentTime: Tool {
        Tool(
            name: "current_time",
            description: "Get the current date and time in ISO 8601 format.",
            tool_schema: .init(properties: [
                "time_zone": .init(type: "string", description: "IANA time zone identifier, such as America/New_York. Defaults to UTC.")
            ]),
            callback: { _, args in
                let identifier = args["time_zone"]?.stringValue ?? "UTC"
                guard let timeZone = TimeZone(identifier: identifier) else { return "Unknown time zone '\(identifier)'." }
                let formatter = ISO8601DateFormatter()
                formatter.timeZone = timeZone
                return formatter.string(from: Date())
            }
        )
    }
}
