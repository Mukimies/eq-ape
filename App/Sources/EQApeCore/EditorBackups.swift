import Foundation

/// Copies config files before the editor first writes them, one folder per editing session:
/// `<base>/<yyyy-MM-dd_HH-mm-ss>/<file name>` plus `manifest.txt` (original paths). Keeps the newest `keep`
/// session folders and deletes older ones (only folders whose names look like session timestamps).
public final class EditorBackups: @unchecked Sendable {
    public let baseDirectory: URL
    public let keep: Int
    public private(set) var sessionDirectory: URL?
    private var backedUp: [URL: URL] = [:]
    private let lock = NSLock()
    private let now: () -> Date

    public static var defaultDirectory: URL { SettingsStore.defaultDirectory.appendingPathComponent("Backups", isDirectory: true) }

    public init(baseDirectory: URL = EditorBackups.defaultDirectory, keep: Int = 20, now: @escaping () -> Date = Date.init) {
        self.baseDirectory = baseDirectory
        self.keep = max(1, keep)
        self.now = now
    }

    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    static func isSessionName(_ s: String) -> Bool {
        s.range(of: #"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}(-\d+)?$"#, options: .regularExpression) != nil
    }

    /// Whether `url` has already been backed up in this session.
    public func hasBackup(of url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return backedUp[url.standardizedFileURL] != nil
    }

    /// Copy `url` (its current bytes on disk) into this session's folder unless already done. Returns the copy.
    @discardableResult
    public func backupIfNeeded(_ url: URL) throws -> URL? {
        lock.lock(); defer { lock.unlock() }
        let key = url.standardizedFileURL
        if let done = backedUp[key] { return done }
        guard FileManager.default.fileExists(atPath: key.path) else { return nil }
        let fm = FileManager.default
        let dir = try ensureSessionDirectory()
        var name = key.lastPathComponent
        var n = 2
        while fm.fileExists(atPath: dir.appendingPathComponent(name).path) {
            let base = (key.lastPathComponent as NSString).deletingPathExtension
            let ext = (key.lastPathComponent as NSString).pathExtension
            name = "\(base) (\(n))" + (ext.isEmpty ? "" : ".\(ext)")
            n += 1
        }
        let dest = dir.appendingPathComponent(name)
        try fm.copyItem(at: key, to: dest)
        backedUp[key] = dest
        let manifest = dir.appendingPathComponent("manifest.txt")
        let line = "\(name)\t\(key.path)\n"
        if let h = try? FileHandle(forWritingTo: manifest) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try Data(("EQ Ape editor backup: copies of the files as they were before the first edit.\n" + line).utf8).write(to: manifest)
        }
        return dest
    }

    private func ensureSessionDirectory() throws -> URL {
        if let d = sessionDirectory { return d }
        let fm = FileManager.default
        try fm.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let stamp = EditorBackups.formatter.string(from: now())
        var dir = baseDirectory.appendingPathComponent(stamp, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: dir.path) {
            dir = baseDirectory.appendingPathComponent("\(stamp)-\(n)", isDirectory: true); n += 1
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: false)
        sessionDirectory = dir
        prune()
        return dir
    }

    /// Delete the oldest session folders beyond `keep`.
    public func prune() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: baseDirectory.path) else { return }
        let sessions = names.filter(EditorBackups.isSessionName).sorted { a, b in
            // timestamp first, then the numeric "-n" suffix
            let (ta, na) = split(a), (tb, nb) = split(b)
            return ta == tb ? na < nb : ta < tb
        }
        guard sessions.count > keep else { return }
        for old in sessions.prefix(sessions.count - keep) {
            try? fm.removeItem(at: baseDirectory.appendingPathComponent(old))
        }
        func split(_ s: String) -> (String, Int) {
            let t = String(s.prefix(19))
            let n = s.count > 20 ? Int(s.dropFirst(20)) ?? 1 : 1
            return (t, n)
        }
    }
}
