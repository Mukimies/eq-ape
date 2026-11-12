import Foundation

/// GUI launch flags (the headless/CLI flags are handled by `Headless`).
///
///   --no-engine              never start the audio engine, taps or device I/O (the device list is read only);
///                            settings are read-only unless --settings is given
///   --editor <config path>   open the editor on this file at launch
///   --settings <file>        use this settings.json instead of ~/Library/Application Support/EQ Ape/settings.json
///   --backup-dir <dir>       editor backups go here instead of ~/Library/Application Support/EQ Ape/Backups
///   --render-snapshots <dir> render the editor, settings and first-run views offscreen to PNG files and exit
///                            (implies --no-engine)
///   --smoke-test             with --editor: drive the editor in-process (synthesised mouse drag on the graph,
///                            undo, redo), print SMOKE lines, keep running until terminated
struct LaunchOptions {
    var noEngine = false
    var editorPath: String?
    var settingsPath: String?
    var backupDir: String?
    var renderSnapshots: String?
    var smokeTest = false

    nonisolated(unsafe) static var current = LaunchOptions()

    static func parse(_ args: [String]) -> LaunchOptions {
        var o = LaunchOptions()
        var i = 0
        func next() -> String? { i += 1; return i < args.count ? args[i] : nil }
        while i < args.count {
            switch args[i] {
            case "--no-engine": o.noEngine = true
            case "--editor": o.editorPath = next().map { ($0 as NSString).expandingTildeInPath }
            case "--settings": o.settingsPath = next().map { ($0 as NSString).expandingTildeInPath }
            case "--backup-dir": o.backupDir = next().map { ($0 as NSString).expandingTildeInPath }
            case "--render-snapshots": o.renderSnapshots = next().map { ($0 as NSString).expandingTildeInPath }; o.noEngine = true
            case "--smoke-test": o.smokeTest = true
            default: break   // e.g. -NSDocumentRevisionsDebugMode, -psn_ from Launch Services
            }
            i += 1
        }
        return o
    }
}
