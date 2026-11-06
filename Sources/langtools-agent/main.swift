//
//  main.swift
//  langtools-agent
//
//  Runs agent specs with every provider that ships with LangTools and the built-in
//  tools. To add tools, build your own executable around `AgentRuntimeCommand`.
//

import Foundation
import AgentRuntime
import AgentRuntimeProviders

let command = AgentRuntimeCommand(providers: .builtIn, tools: .builtIn)
exit(await command.run(Array(CommandLine.arguments.dropFirst())))
