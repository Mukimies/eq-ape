import ServiceManagement
import Foundation

// One binary, several modes:
//   EQApe                         -> menu bar app (SwiftUI MenuBarExtra); GUI flags in LaunchOptions.swift
//   EQApe --no-engine [...]       -> GUI without any audio engine, taps or device I/O
//   EQApe --render-snapshots dir  -> render views offscreen to PNG and exit (no engine)
//   EQApe --print-permission      -> print permission preflights + code-signing identity (JSON line) and exit
//   EQApe --headless ...          -> terminal test mode (status line per second), see Headless.swift
//   EQApe --list | --get-default | --set-default <name> | --probe --device <name> | --taps
let cliCommands: Set<String> = ["--headless", "--list", "--get-default", "--set-default", "--set-rate", "--probe", "--taps", "--help", "-h"]
let launchArgs = Array(CommandLine.arguments.dropFirst())
if launchArgs.contains(where: { cliCommands.contains($0) }) {
    Headless.main(launchArgs)
} else {
    LaunchOptions.current = LaunchOptions.parse(launchArgs)
    if LaunchOptions.current.printPermission {
        PermissionCheck.printReport()
        exit(0)
    }
    if let action = LaunchOptions.current.loginItem {
        do {
            if action == "on" { try SMAppService.mainApp.register() }
            if action == "off" { try SMAppService.mainApp.unregister() }
        } catch { print("EQ Ape login item: error: \(error.localizedDescription)") }
        let names: [SMAppService.Status: String] = [.enabled: "enabled", .notRegistered: "not registered",
                                                    .requiresApproval: "requires approval", .notFound: "not found"]
        print("EQ Ape login item: \(names[SMAppService.mainApp.status] ?? "unknown") (\(Bundle.main.bundlePath))")
        exit(0)
    }
    if let dir = LaunchOptions.current.renderSnapshots {
        MainActor.assumeIsolated { SnapshotRenderer.run(outputDirectory: dir) }
    } else {
        EQApeApp.main()
    }
}
