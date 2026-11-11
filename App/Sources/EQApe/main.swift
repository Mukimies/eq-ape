import Foundation

// One binary, two modes:
//   EQApe                    -> menu bar app (SwiftUI MenuBarExtra)
//   EQApe --headless ...     -> terminal test mode (status line per second), see Headless.swift
//   EQApe --list | --get-default | --set-default <name> | --probe --device <name> | --taps
let cliCommands: Set<String> = ["--headless", "--list", "--get-default", "--set-default", "--set-rate", "--probe", "--taps", "--help", "-h"]
if CommandLine.arguments.dropFirst().contains(where: { cliCommands.contains($0) }) {
    Headless.main(Array(CommandLine.arguments.dropFirst()))
} else {
    EQApeApp.main()
}
