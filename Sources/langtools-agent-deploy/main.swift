//
//  main.swift
//  langtools-agent-deploy
//
//  Manages langtools-agent workers on this machine, on servers reachable over SSH, and
//  on DigitalOcean droplets. Needs docker for local workers, ssh for remote hosts, and
//  doctl (authenticated with `doctl auth init`) to create DigitalOcean hosts.
//

import Foundation
import AgentDeploy

let runner = ProcessCommandRunner()
let environment = ProcessInfo.processInfo.environment
let store = FleetStore(file: FleetStore.defaultDirectory(environment: environment).appendingPathComponent("fleet.json"))
let digitalOcean = DigitalOceanCompute(runner: runner, doctl: environment["DOCTL"] ?? "doctl", context: environment["DOCTL_CONTEXT"])
let fleet = AgentFleet(store: store, runner: runner, providers: [digitalOcean], log: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })
exit(await AgentDeployCommand(fleet: fleet, environment: environment).run(Array(CommandLine.arguments.dropFirst())))
