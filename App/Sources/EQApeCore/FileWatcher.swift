import Foundation

/// Watches a set of files (the config plus everything it Includes) and calls `onChange` once the
/// files have changed and then stayed unchanged for one more poll (so a save in progress is not read
/// half-written).
///
/// Implementation: `stat()` polling (default every 0.25 s). That is a handful of syscalls per tick,
/// works for files that do not exist yet, and survives editors that save by writing a temporary file
/// and renaming it over the original (which defeats a kqueue watch on the old inode). Change detection
/// + settle = 0.25-0.5 s, leaving room for the EQ rebuild within about a second.
public final class FileWatcher: @unchecked Sendable {
    struct Stamp: Equatable {
        var exists: Bool
        var inode: UInt64 = 0
        var size: Int64 = 0
        var mtimeSec: Int = 0
        var mtimeNsec: Int = 0
    }

    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var files: [URL] = []
    private var last: [Stamp] = []
    private var pending: [Stamp]?
    private let interval: TimeInterval
    public var onChange: (() -> Void)?

    public init(interval: TimeInterval = 0.25, queue: DispatchQueue = DispatchQueue(label: "EQApe.filewatch")) {
        self.interval = interval
        self.queue = queue
    }

    deinit { timer?.cancel() }

    /// Replace the watch list; the current state becomes the baseline (no callback for it).
    public func watch(_ urls: [URL]) {
        queue.sync {
            files = urls
            last = urls.map(Self.stamp)
            pending = nil
            if timer == nil {
                let t = DispatchSource.makeTimerSource(queue: queue)
                t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(20))
                t.setEventHandler { [weak self] in self?.tick() }
                t.resume()
                timer = t
            }
        }
    }

    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            files = []
            last = []
            pending = nil
        }
    }

    private func tick() {
        let now = files.map(Self.stamp)
        if let p = pending {
            if now == p {               // settled: unchanged for one full interval
                pending = nil
                last = now
                onChange?()
            } else {
                pending = now           // still changing
            }
        } else if now != last {
            pending = now
        }
    }

    static func stamp(_ url: URL) -> Stamp {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return Stamp(exists: false) }
        return Stamp(exists: true, inode: UInt64(st.st_ino), size: Int64(st.st_size),
                     mtimeSec: Int(st.st_mtimespec.tv_sec), mtimeNsec: Int(st.st_mtimespec.tv_nsec))
    }
}
