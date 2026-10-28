//
//  main.swift
//  langtools-agent-deploy
//
//  Manages langtools-agent workers on DigitalOcean. Requires doctl (authenticated
//  with `doctl auth init`) and ssh on PATH.
//

import Foundation
import AgentDeploy

let runner = ProcessCommandRunner()
let environment = ProcessInfo.processInfo.environment
let compute = DigitalOceanCompute(runner: runner, doctl: environment["DOCTL"] ?? "doctl", context: environment["DOCTL_CONTEXT"])
let command = AgentDeployCommand(compute: compute, runner: runner, environment: environment)
exit(await command.run(Array(CommandLine.arguments.dropFirst())))
