import Foundation

/// GUI launch flags (the headless/CLI flags are handled by `Headless`).
///
///   --no-engine              never start the audio engine, taps or device I/O (the device list is read only);
///                            settings are read-only unless --settings is given
///   --require-granted        start an engine only if the no-prompt preflights say no permission prompt can appear
///                            (audio capture "granted"; Microphone decided when the device has inputs). Otherwise the
///                            engine stays off (state "engine off: …", printed to stdout). For every unattended run.
///   --print-permission       print the permission preflights and this binary's code-signing identity as one JSON
///                            line on stdout, then exit (never starts anything)
///   --editor <config path>   open the editor on this file at launch
///   --settings <file>        use this settings.json instead of ~/Library/Application Support/EQ Ape/settings.json
///   --backup-dir <dir>       editor backups go here instead of ~/Library/Application Support/EQ Ape/Backups
///   --render-snapshots <dir> render the editor, settings and first-run views offscreen to PNG files and exit
///                            (implies --no-engine)
///   --smoke-test             with --editor: drive the editor in-process (synthesised mouse drag on the graph,
///                            undo, redo), print SMOKE lines, keep running until terminated
///   --ui-test-control <dir>  development/test hook: watch <dir>/cmd for JSON commands, answer in <dir>/res
///                            (docs/UI-TESTING.md). Also: no window-frame or first-run writes to user defaults.
struct LaunchOptions {
    var noEngine = false
    var requireGranted = false
    var printPermission = false
    /// --login-item status|on|off: read or change the "launch at login" item of this bundle, print it and exit.
    var loginItem: String?
    var editorPath: String?
    var settingsPath: String?
    var backupDir: String?
    var renderSnapshots: String?
    var smokeTest = false
    var uiTestControl: String?

    nonisolated(unsafe) static var current = LaunchOptions()

    var uiTest: Bool { uiTestControl != nil }

    static func parse(_ args: [String]) -> LaunchOptions {
        var o = LaunchOptions()
        var i = 0
        func next() -> String? { i += 1; return i < args.count ? args[i] : nil }
        while i < args.count {
            switch args[i] {
            case "--no-engine": o.noEngine = true
            case "--require-granted": o.requireGranted = true
            case "--print-permission": o.printPermission = true
            case "--login-item": i += 1; o.loginItem = i < args.count ? args[i] : "status"
            case "--editor": o.editorPath = next().map { ($0 as NSString).expandingTildeInPath }
            case "--settings": o.settingsPath = next().map { ($0 as NSString).expandingTildeInPath }
            case "--backup-dir": o.backupDir = next().map { ($0 as NSString).expandingTildeInPath }
            case "--render-snapshots": o.renderSnapshots = next().map { ($0 as NSString).expandingTildeInPath }; o.noEngine = true
            case "--smoke-test": o.smokeTest = true
            case "--ui-test-control": o.uiTestControl = next().map { ($0 as NSString).expandingTildeInPath }
            default: break   // e.g. -NSDocumentRevisionsDebugMode, -psn_ from Launch Services
            }
            i += 1
        }
        return o
    }
}
