import Darwin
import Foundation

/// Decides, before an engine is built, whether starting it is safe. Two independent checks:
///
/// 1. **Permission gate** (`--require-granted`, for unattended and scripted runs): `AudioDeviceStart` on an aggregate
///    with a tap makes coreaudiod ask TCC for the audio-capture permission and blocks until the prompt is answered;
///    while such a prompt is pending no process on the Mac can start new audio. With the gate on, the engine starts
///    only when the no-prompt preflights say no prompt can appear: audio capture must be "granted" for the
///    responsible process. The Microphone status is reported but does not gate: the engine disables the device's
///    input streams in its IOProc, and on 2026-11-12 it ran on a Scarlett Solo USB (2 input streams) with Microphone
///    "not determined" and raised no Microphone prompt. Observed on that one device only.
/// 2. **Instance guard** (always on in the GUI): two taps on one device would process the audio twice. Another
///    EQ Ape process blocks the engine unless it has declared, in the instance registry, that its engine is off or
///    that it processes a different device. A process without a registry entry (an older build) is assumed to be
///    processing, conservatively.
///
/// The decisions are pure functions (unit tested); the I/O helpers below gather their inputs.
public enum EngineGate {
    /// Audio-capture preflight result (mirrors `TapKit.Permission.State`, kept separate so this stays pure).
    public enum Capture: String, Sendable { case granted, denied, notDetermined = "not determined", unknown }
    /// Microphone authorization (mirrors `AVAuthorizationStatus`).
    public enum Microphone: String, Sendable { case authorized, denied, restricted, notDetermined = "not determined", unknown }

    public struct PermissionInputs: Equatable, Sendable {
        public var capture: Capture
        public var microphone: Microphone
        public var deviceHasInputs: Bool
        public init(capture: Capture, microphone: Microphone, deviceHasInputs: Bool) {
            self.capture = capture; self.microphone = microphone; self.deviceHasInputs = deviceHasInputs
        }
    }

    /// nil = safe to start; otherwise the reason the engine must stay off.
    public static func permissionBlock(_ p: PermissionInputs, requireGranted: Bool) -> String? {
        guard requireGranted else { return nil }
        if p.capture != .granted {
            return "audio-capture permission is \(p.capture.rawValue) for this process (--require-granted: starting would raise a prompt)"
        }
        return nil
    }

    public enum BlockedStartAction: Equatable, Sendable { case wait, retry, giveUp(String) }

    /// What to do while an engine start is blocked (AudioDeviceStart did not return, normally because the
    /// audio-capture prompt is still open). Retrying is only safe once the permission is granted, and only once.
    public static func blockedStartAction(permission: Capture, autoRetried: Bool) -> BlockedStartAction {
        switch permission {
        case .notDetermined, .unknown: return .wait
        case .denied: return .giveUp("audio capture was denied: allow EQ Ape under System Settings > Privacy & Security > Screen & System Audio Recording, then choose Reload")
        case .granted:
            return autoRetried ? .giveUp("audio start blocked although the permission is granted: choose Reload") : .retry
        }
    }

    /// Another EQ Ape process, as seen from this one.
    public struct Peer: Equatable, Sendable {
        public var pid: Int32
        public var path: String
        /// Its registry entry, if it wrote one (builds with the instance registry do).
        public var entry: InstanceRegistry.Entry?
        public init(pid: Int32, path: String, entry: InstanceRegistry.Entry?) { self.pid = pid; self.path = path; self.entry = entry }
    }

    /// nil = no other instance can be processing `deviceUID`; otherwise the reason to keep the engine off.
    public static func instanceBlock(peers: [Peer], deviceUID: String) -> String? {
        for p in peers {
            guard let e = p.entry, e.pid == p.pid else {
                return "another EQ Ape process (pid \(p.pid), \(p.path)) is running and does not report its engine state; it may be processing this device"
            }
            if !e.engineMayRun { continue }
            if let uid = e.deviceUID, uid != deviceUID { continue }
            return "another EQ Ape process (pid \(p.pid)) is processing \(e.deviceName ?? e.deviceUID ?? "this device"); two taps would process the audio twice"
        }
        return nil
    }
}

/// Instance registry: one small JSON file per running EQ Ape process in a per-user temporary directory
/// (`$TMPDIR/org.eqape.EQApe.instances/<pid>.json`), plus a per-device `flock` lock held while an engine exists.
/// No sockets, no network: processes find each other through the process table (libproc) and these files. The
/// kernel drops a `flock` when its process dies, so a crash never leaves a stale device lock; registry files of dead
/// processes are ignored (the pid is checked) and removed by the next instance.
public enum InstanceRegistry {
    public struct Entry: Codable, Equatable, Sendable {
        public var pid: Int32
        public var executable: String
        /// "off" (--no-engine or held), "following" (may start an engine on the default output), "active".
        public var engine: String
        public var deviceUID: String?
        public var deviceName: String?
        public var uiTest: Bool
        public var started: Date
        public init(pid: Int32, executable: String, engine: String, deviceUID: String?, deviceName: String?, uiTest: Bool, started: Date) {
            self.pid = pid; self.executable = executable; self.engine = engine; self.deviceUID = deviceUID
            self.deviceName = deviceName; self.uiTest = uiTest; self.started = started
        }
        /// False only when the process declared that it never starts an engine.
        public var engineMayRun: Bool { engine != "off" }
    }

    public static var directory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("org.eqape.EQApe.instances", isDirectory: true)
    }

    public static func write(_ e: Entry, directory dir: URL = directory) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let d = try? enc.encode(e) else { return }
        try? d.write(to: dir.appendingPathComponent("\(e.pid).json"), options: .atomic)
    }

    public static func remove(pid: Int32 = getpid(), directory dir: URL = directory) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(pid).json"))
    }

    public static func read(pid: Int32, directory dir: URL = directory) -> Entry? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("\(pid).json")) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Entry.self, from: d)
    }

    /// Other live processes whose executable is named `EQApe` (any build, any location), with their entries.
    /// Stale registry files (dead pids) are removed on the way.
    public static func peers(directory dir: URL = directory) -> [EngineGate.Peer] {
        let me = getpid()
        var out: [EngineGate.Peer] = []
        for (pid, path) in processes(named: "EQApe") where pid != me {
            out.append(EngineGate.Peer(pid: pid, path: path, entry: read(pid: pid, directory: dir)))
        }
        if let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for f in files where f.hasSuffix(".json") {
                if let pid = Int32(f.dropLast(5)), pid != me, kill(pid, 0) != 0, errno == ESRCH {
                    try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
                }
            }
        }
        return out
    }

    /// (pid, executable path) of every process whose executable file name is `name` (libproc, no privileges).
    public static func processes(named name: String) -> [(Int32, String)] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard got > 0 else { return [] }
        var out: [(Int32, String)] = []
        var buf = [CChar](repeating: 0, count: 4 * 1024)
        for pid in pids.prefix(Int(got)) where pid > 0 {
            let len = proc_pidpath(pid, &buf, UInt32(buf.count))
            guard len > 0 else { continue }
            let path = String(cString: buf)
            if (path as NSString).lastPathComponent == name { out.append((pid, path)) }
        }
        return out
    }

    /// Per-device lock held while this process has an engine on `uid`. Returns nil when another process holds it.
    public final class DeviceLock {
        public let uid: String
        private let fd: Int32
        init?(uid: String, directory dir: URL) {
            self.uid = uid
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let safe = uid.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
            let path = dir.appendingPathComponent("device-\(safe).lock").path
            let fd = open(path, O_RDWR | O_CREAT, 0o644)
            guard fd >= 0 else { return nil }
            if flock(fd, LOCK_EX | LOCK_NB) != 0 { close(fd); return nil }
            self.fd = fd
        }
        deinit { flock(fd, LOCK_UN); close(fd) }
    }

    public static func lockDevice(_ uid: String, directory dir: URL = directory) -> DeviceLock? {
        DeviceLock(uid: uid, directory: dir)
    }
}
