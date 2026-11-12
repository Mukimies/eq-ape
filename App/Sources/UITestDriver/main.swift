// eqape-uitest: driver of EQ Ape's --ui-test-control channel (docs/UI-TESTING.md). Run it through App/scripts/uitest.
//
//   uitest launch [--engine | --no-engine] [--config <file>] [--settings <file>] [--own-identity] [--editor | --no-editor]
//   uitest do <action> [key=value ...] | uitest do '<json>'
//   uitest state [path]
//   uitest shot <name> [window]
//   uitest quit
//   uitest status
//   uitest suite [--out <dir>]
//
// Safety rules (enforced here, not just documented):
//   - only bundles under App/build-dev/ are ever launched (never App/build/);
//   - --engine always adds --require-granted, and is refused while any other EQ Ape process runs (the app's own
//     instance guard would hold the engine anyway);
//   - scratch copies of the config, a scratch settings.json and a scratch backup directory are used unless told
//     otherwise; --no-engine is the default;
//   - only the session's own pid is ever signalled, after checking that its executable lives under App/build-dev/.
import Darwin
import Foundation

// MARK: paths

let env = ProcessInfo.processInfo.environment
let appDir: URL = {
    if let d = env["EQAPE_APP_DIR"] { return URL(fileURLWithPath: d, isDirectory: true).standardizedFileURL }
    // .build/<triple>/debug/eqape-uitest -> App/
    var u = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    for _ in 0..<4 { u.deleteLastPathComponent() }
    return u
}()
let bundleURL = URL(fileURLWithPath: env["EQAPE_UITEST_BUNDLE"] ?? appDir.appendingPathComponent("build-dev/EQ Ape.app").path)
let executable = bundleURL.appendingPathComponent("Contents/MacOS/EQApe").path
let sessionDir = URL(fileURLWithPath: env["EQAPE_UITEST_SESSION"] ?? appDir.appendingPathComponent(".scratch/uitest/session").path, isDirectory: true)
let ctlDir = sessionDir.appendingPathComponent("ctl", isDirectory: true)

func die(_ s: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("uitest: \(s)\n".utf8))
    exit(code)
}

func guardBundle() {
    let p = bundleURL.standardizedFileURL.path
    guard p.contains("/build-dev/") else { die("refusing to launch \(p): only bundles under App/build-dev/ are used (App/build/ belongs to the owner's running instance)") }
    guard FileManager.default.isExecutableFile(atPath: executable) else { die("no bundle at \(p); build it with: cd App && BUILD_DIR=build-dev ./bundle.sh") }
}

// MARK: processes

func processes(named name: String) -> [(pid: Int32, path: String)] {
    let n = proc_listallpids(nil, 0)
    guard n > 0 else { return [] }
    var pids = [Int32](repeating: 0, count: Int(n) + 64)
    let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
    var out: [(Int32, String)] = []
    var buf = [CChar](repeating: 0, count: 4096)
    for pid in pids.prefix(Int(max(0, got))) where pid > 0 {
        if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 {
            let path = String(cString: buf)
            if (path as NSString).lastPathComponent == name { out.append((pid, path)) }
        }
    }
    return out
}

func pidPath(_ pid: Int32) -> String? {
    var buf = [CChar](repeating: 0, count: 4096)
    return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
}

func alive(_ pid: Int32) -> Bool {
    var st: Int32 = 0
    _ = waitpid(pid, &st, WNOHANG)   // reap our own spawned child (no-op for other processes)
    return kill(pid, 0) == 0 || errno == EPERM
}

// MARK: session file

struct Session: Codable {
    var pid: Int32
    var engine: Bool
    var config: String?
    var settings: String
    var started: Date
}

let sessionFile = sessionDir.appendingPathComponent("session.json")

func loadSession() -> Session? {
    guard let d = try? Data(contentsOf: sessionFile) else { return nil }
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    return try? dec.decode(Session.self, from: d)
}

func saveSession(_ s: Session) {
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try? enc.encode(s).write(to: sessionFile)
}

/// The running session's pid, only if it is alive and really is our dev bundle.
func liveSession() -> Session? {
    guard let s = loadSession(), alive(s.pid), let p = pidPath(s.pid), p.contains("/build-dev/") else { return nil }
    return s
}

// MARK: channel

var seq = 0
func send(_ cmd: [String: Any], timeout: Double = 30) -> [String: Any] {
    seq += 1
    let name = String(format: "%020llu-%04d.json", UInt64(Date().timeIntervalSince1970 * 1e9), seq)
    let tmp = ctlDir.appendingPathComponent("cmd/.\(name).tmp")
    guard let d = try? JSONSerialization.data(withJSONObject: cmd) else { die("bad command") }
    try? FileManager.default.createDirectory(at: ctlDir.appendingPathComponent("cmd"), withIntermediateDirectories: true)
    try? d.write(to: tmp)
    try? FileManager.default.moveItem(at: tmp, to: ctlDir.appendingPathComponent("cmd/\(name)"))
    let res = ctlDir.appendingPathComponent("res/\(name)")
    let t0 = Date()
    while Date().timeIntervalSince(t0) < timeout {
        if let data = try? Data(contentsOf: res), let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            try? FileManager.default.removeItem(at: res)
            return obj
        }
        usleep(15_000)
    }
    return ["ok": false, "error": "no answer within \(timeout) s (is the app running? uitest status)"]
}

func json(_ o: Any) -> String {
    guard JSONSerialization.isValidJSONObject(o) || o is [Any] || o is [String: Any],
          let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "\(o)" }
    return String(data: d, encoding: .utf8) ?? ""
}

func lookup(_ root: Any?, _ path: String) -> Any? {
    var cur = root
    for part in path.split(separator: ".") {
        var key = String(part)
        var idx: Int?
        if let b = key.firstIndex(of: "["), key.hasSuffix("]") {
            idx = Int(key[key.index(after: b)..<key.index(before: key.endIndex)])
            key = String(key[..<b])
        }
        if !key.isEmpty { cur = (cur as? [String: Any])?[key] }
        if let i = idx { cur = (cur as? [Any]).flatMap { $0.indices.contains(i) ? $0[i] : nil } }
        if cur == nil || cur is NSNull { return nil }
    }
    return cur
}

// MARK: launch

func defaultOutputUID() -> (uid: String, name: String)? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: executable)
    p.arguments = ["--list"]   // read-only HAL query
    let pipe = Pipe()
    p.standardOutput = pipe
    try? p.run()
    p.waitUntilExit()
    let lines = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.components(separatedBy: "\n") ?? []
    for (i, l) in lines.enumerated() where l.contains("*default") && i + 1 < lines.count {
        let name = l.split(separator: " ", omittingEmptySubsequences: true).dropFirst().prefix { $0 != "out" }.joined(separator: " ")
        if let r = lines[i + 1].range(of: "UID: ") { return (String(lines[i + 1][r.upperBound...]), name) }
    }
    return nil
}

let sampleConfig = """
# EQ Ape UI test config (generated scratch copy)
Preamp: -3 dB
Filter 1: ON PK Fc 120 Hz Gain -6 dB Q 4
Filter 2: ON LSC Fc 80 Hz Gain 3 dB
Filter 3: OFF HSC Fc 8000 Hz Gain 2 dB
# Filter: ON PK Fc 400 Hz Gain -2 dB Q 2
GraphicEQ: 20 4; 45 4; 70 0; 400 -1.5; 900 1; 2500 -2; 6000 0; 12000 2.5; 20000 0
This line is not valid
Include: suite-extra.txt

"""
let sampleExtra = "Filter 4: ON PK Fc 3000 Hz Gain -2 dB Q 1.5\n"

struct LaunchOptions {
    var engine = false
    var config: String?
    var settings: String?
    var ownIdentity = false
    var openEditor = true
    var inPlace = false
}

@discardableResult
func launch(_ o: LaunchOptions) -> Session {
    guardBundle()
    if let s = liveSession() { die("a dev session is already running (pid \(s.pid)); uitest quit first") }
    let others = processes(named: "EQApe")
    if o.engine && !others.isEmpty {
        die("refusing --engine: other EQ Ape process(es) are running (\(others.map { "\($0.pid) \($0.path)" }.joined(separator: ", "))); two taps on one device would process the audio twice. Use --no-engine.")
    }
    let fm = FileManager.default
    try? fm.removeItem(at: sessionDir)
    try? fm.createDirectory(at: ctlDir, withIntermediateDirectories: true)
    let cfgDir = sessionDir.appendingPathComponent("config", isDirectory: true)
    try? fm.createDirectory(at: cfgDir, withIntermediateDirectories: true)
    var configPath: String
    if let c = o.config {
        let src = URL(fileURLWithPath: (c as NSString).expandingTildeInPath).standardizedFileURL
        if o.inPlace {
            configPath = src.path
        } else {
            // scratch copy of the file and its siblings (Include targets)
            for f in (try? fm.contentsOfDirectory(atPath: src.deletingLastPathComponent().path)) ?? [] where f.lowercased().hasSuffix(".txt") {
                try? fm.copyItem(at: src.deletingLastPathComponent().appendingPathComponent(f), to: cfgDir.appendingPathComponent(f))
            }
            configPath = cfgDir.appendingPathComponent(src.lastPathComponent).path
            if !fm.fileExists(atPath: configPath) { try? fm.copyItem(at: src, to: URL(fileURLWithPath: configPath)) }
        }
    } else {
        configPath = cfgDir.appendingPathComponent("suite.txt").path
        try? sampleConfig.write(toFile: configPath, atomically: true, encoding: .utf8)
        try? sampleExtra.write(to: cfgDir.appendingPathComponent("suite-extra.txt"), atomically: true, encoding: .utf8)
    }
    let settingsPath = o.settings.map { ($0 as NSString).expandingTildeInPath } ?? sessionDir.appendingPathComponent("settings.json").path
    if o.settings == nil {
        var profiles: [String: Any] = [
            "uid-uitest-unplugged": ["deviceName": "Unplugged Test Device", "enabled": true, "configPath": configPath,
                                     "headroomEnabled": true, "headroomDB": 0.5]]
        if let d = defaultOutputUID() {
            profiles[d.uid] = ["deviceName": d.name, "enabled": true, "configPath": configPath, "headroomEnabled": true, "headroomDB": 0.5]
        }
        let s: [String: Any] = ["version": 1, "enabled": true, "profiles": profiles]
        try? JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: settingsPath))
    }
    var args = ["--require-granted", "--settings", settingsPath, "--backup-dir", sessionDir.appendingPathComponent("backups").path,
                "--ui-test-control", ctlDir.path]
    if !o.engine { args.insert("--no-engine", at: 0) }
    if o.openEditor { args += ["--editor", configPath] }
    let log = sessionDir.appendingPathComponent("app.log").path
    var pid: Int32 = 0
    if o.ownIdentity {
        // Launch Services: the app is its own TCC responsible process (as when a user opens it)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", bundleURL.path, "--stdout", log, "--stderr", log, "--args"] + args
        try? p.run()
        p.waitUntilExit()
    } else {
        // child of this terminal (TCC responsible process: the terminal), in its own session so it survives us
        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fa, 1, log, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        posix_spawn_file_actions_adddup2(&fa, 1, 2)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        let argv = ([executable] + args).map { strdup($0) } + [nil]
        let rc = posix_spawn(&pid, executable, &fa, &attr, argv, environ)
        argv.forEach { free($0) }
        if rc != 0 { die("posix_spawn failed: \(rc)") }
    }
    // wait for the channel
    let ready = ctlDir.appendingPathComponent("app.json")
    let t0 = Date()
    while Date().timeIntervalSince(t0) < 20 {
        if let d = try? Data(contentsOf: ready), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let p = j["pid"] as? Int {
            pid = Int32(p); break
        }
        usleep(50_000)
    }
    guard pid > 0, alive(pid) else { die("the app did not open its channel within 20 s; log: \(log)") }
    let s = Session(pid: pid, engine: o.engine, config: o.openEditor ? configPath : nil, settings: settingsPath, started: Date())
    saveSession(s)
    print("launched pid \(pid) (\(o.engine ? "engine requested, --require-granted" : "--no-engine")), session \(sessionDir.path)")
    print("config: \(configPath)")
    return s
}

func quit() {
    guard let s = liveSession() else { print("no dev session running"); return }
    _ = send(["action": "quit"], timeout: 5)
    let t0 = Date()
    while alive(s.pid) && Date().timeIntervalSince(t0) < 6 { usleep(100_000) }
    if alive(s.pid), let p = pidPath(s.pid), p.contains("/build-dev/") {
        kill(s.pid, SIGTERM)   // the session's own dev pid only
        usleep(1_500_000)
    }
    print(alive(s.pid) ? "pid \(s.pid) still running" : "pid \(s.pid) exited")
}

/// key=value pairs; values parsed as JSON when possible ("3", "true", "[1,2]"), else strings.
func parseArgs(_ action: String, _ rest: [String]) -> [String: Any] {
    if action.hasPrefix("{"), let d = action.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] { return o }
    var cmd: [String: Any] = ["action": action]
    for a in rest {
        guard let eq = a.firstIndex(of: "=") else { cmd["target"] = a; continue }
        let k = String(a[..<eq]), v = String(a[a.index(after: eq)...])
        let stringKeys: Set<String> = ["text", "target", "to", "row", "match", "key", "item", "button", "name", "path", "window", "mode", "open", "at"]
        if stringKeys.contains(k) { cmd[k] = v; continue }
        if let d = v.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]), !(j is String) { cmd[k] = j }
        else { cmd[k] = v }
    }
    return cmd
}

// MARK: main

var argv = Array(CommandLine.arguments.dropFirst())
guard let verb = argv.first else {
    print("usage: uitest launch [--engine|--no-engine] [--config <file>] [--settings <file>] [--own-identity] [--no-editor] [--in-place]\n" +
          "       uitest do <action> [key=value ...] | uitest state [path] | uitest shot <name> [window] | uitest quit | uitest status | uitest suite [--out <dir>]")
    exit(2)
}
argv.removeFirst()

switch verb {
case "launch":
    var o = LaunchOptions()
    var i = 0
    while i < argv.count {
        switch argv[i] {
        case "--engine": o.engine = true
        case "--no-engine": o.engine = false
        case "--config": i += 1; o.config = i < argv.count ? argv[i] : nil
        case "--settings": i += 1; o.settings = i < argv.count ? argv[i] : nil
        case "--own-identity": o.ownIdentity = true
        case "--no-editor": o.openEditor = false
        case "--in-place": o.inPlace = true
        default: die("unknown launch option \(argv[i])")
        }
        i += 1
    }
    launch(o)
case "do":
    guard liveSession() != nil else { die("no dev session running (uitest launch)") }
    guard let a = argv.first else { die("uitest do <action> [key=value ...]") }
    let r = send(parseArgs(a, Array(argv.dropFirst())), timeout: 60)
    print(json(r))
    exit((r["ok"] as? Bool) == false ? 1 : 0)
case "state":
    guard liveSession() != nil else { die("no dev session running (uitest launch)") }
    let r = send(["action": "state"])
    if let p = argv.first { print(json(lookup(r["state"], p) ?? NSNull())) } else { print(json(r["state"] ?? r)) }
case "shot":
    guard liveSession() != nil else { die("no dev session running (uitest launch)") }
    let r = send(["action": "shot", "name": argv.first ?? "shot", "window": argv.count > 1 ? argv[1] : "editor"])
    print(json(r))
    exit((r["ok"] as? Bool) == false ? 1 : 0)
case "quit":
    quit()
case "status":
    if let s = liveSession() { print("dev session: pid \(s.pid), engine \(s.engine), started \(s.started)") } else { print("no dev session running") }
    for p in processes(named: "EQApe") { print("EQ Ape process \(p.pid): \(p.path)\(p.path.contains("/build-dev/") ? "" : "   <- not a dev bundle: never touched by uitest")") }
case "suite":
    var out: String?
    if let i = argv.firstIndex(of: "--out"), i + 1 < argv.count { out = argv[i + 1] }
    exit(Suite.run(outDir: out))
default:
    die("unknown command \(verb)")
}
