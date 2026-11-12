import EQCore
import Foundation

/// The editor's model without UI: a `ConfigWorkspace` whose edits are written to disk after a short debounce, so the
/// running engine's file watcher picks them up while the user drags. Before the first write to a file in a session,
/// the file is copied by `EditorBackups`. Files changed on disk by someone else are reloaded.
///
/// Use from one thread (the main thread in the app). Timers run on the main run loop.
public final class ConfigEditSession {
    public let workspace: ConfigWorkspace
    public let backups: EditorBackups
    /// Debounce between an edit and the write (seconds).
    public var saveDelay: TimeInterval = 0.15

    /// Called after documents changed (edit, undo, redo, revert, external reload).
    public var onChange: (() -> Void)?
    /// A file changed on disk while it had unsaved edits. Return true to reload it (dropping the edits), false to
    /// keep the edits (they are written over the file at the next save). Default: reload.
    public var onConflict: ((URL) -> Bool)?
    /// Informational: a file was reloaded because it changed on disk.
    public var onExternalReload: ((URL) -> Void)?

    /// Files with edits not yet written.
    public private(set) var pending: Set<URL> = []
    /// Last write or read error, if any.
    public private(set) var lastError: String?
    /// Number of writes done (for tests and the status line).
    public private(set) var writeCount = 0

    private var known: [URL: Data] = [:]                 // bytes we believe are on disk
    private var stamps: [URL: FileWatcher.Stamp] = [:]
    private var saveWork: DispatchWorkItem?
    private var watchTimer: Timer?

    public init(rootURL: URL, backups: EditorBackups = EditorBackups()) throws {
        workspace = try ConfigWorkspace(rootURL: rootURL)
        self.backups = backups
        syncKnown()
    }

    deinit { watchTimer?.invalidate(); saveWork?.cancel() }

    // MARK: editing

    /// Apply an edit to the document of `url` (undoable; see `ConfigWorkspace.edit`) and schedule a save.
    @discardableResult
    public func edit(_ url: URL, name: String = "Edit", coalesceKey: String? = nil,
                     _ change: (inout ConfigDocument) throws -> Void) -> Bool {
        guard workspace.edit(url, name: name, coalesceKey: coalesceKey, change) else { return false }
        markPending([ConfigWorkspace.key(url)])
        return true
    }

    public func endCoalescing() { workspace.endCoalescing() }

    @discardableResult public func undo() -> Bool {
        guard let urls = workspace.undo() else { return false }
        markPending(urls); return true
    }

    @discardableResult public func redo() -> Bool {
        guard let urls = workspace.redo() else { return false }
        markPending(urls); return true
    }

    /// Every file back to the bytes it had when the editor opened it (undoable).
    @discardableResult public func revertToVersionAtOpen() -> Bool {
        let urls = workspace.revertToOriginals()
        if urls.isEmpty { return false }
        markPending(urls); return true
    }

    private func markPending(_ urls: [URL]) {
        pending.formUnion(urls)
        syncKnown()
        onChange?()
        scheduleSave()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.flush() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDelay, execute: w)
    }

    /// Write all pending files now.
    public func flush() {
        saveWork?.cancel(); saveWork = nil
        for url in pending.sorted(by: { $0.path < $1.path }) {
            guard let doc = workspace.document(url), !doc.readOnly else { pending.remove(url); continue }
            let data = doc.data()
            if known[url] == data { pending.remove(url); continue }
            do {
                try backups.backupIfNeeded(url)
                // In place (not rename-over): keeps the file's inode, permissions and extended attributes.
                // The engine's watcher waits until the file has been stable for one poll before reading it.
                try data.write(to: url)
                known[url] = data
                stamps[url] = FileWatcher.stamp(url)
                writeCount += 1
                lastError = nil
                pending.remove(url)
            } catch {
                lastError = "could not save \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    // MARK: external changes

    /// Poll the files every `interval` seconds on the main run loop.
    public func startWatching(interval: TimeInterval = 0.5) {
        watchTimer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.checkExternalChanges() }
        RunLoop.main.add(t, forMode: .common)
        watchTimer = t
    }

    public func stopWatching() { watchTimer?.invalidate(); watchTimer = nil }

    /// Compare the files on disk with what this session wrote or loaded; reload the ones changed by someone else.
    /// Returns the reloaded URLs.
    @discardableResult
    public func checkExternalChanges() -> [URL] {
        var reloaded: [URL] = []
        for url in workspace.documents.keys.sorted(by: { $0.path < $1.path }) {
            let st = FileWatcher.stamp(url)
            if stamps[url] == st { continue }
            stamps[url] = st
            guard st.exists, let data = try? Data(contentsOf: url) else { continue }
            if known[url] == data { continue }
            if pending.contains(url) {
                let reload = onConflict?(url) ?? true
                if !reload { continue }
                pending.remove(url)
            }
            if workspace.reloadFromDisk(url) {
                known[url] = data
                reloaded.append(url)
                onExternalReload?(url)
            }
        }
        if !reloaded.isEmpty { syncKnown(); onChange?() }
        return reloaded
    }

    /// Record disk bytes for documents loaded since the last call (new Include targets).
    private func syncKnown() {
        for (u, d) in workspace.documents where known[u] == nil {
            known[u] = workspace.originals[u] == d ? d.data() : (try? Data(contentsOf: u)) ?? d.data()
            stamps[u] = FileWatcher.stamp(u)
        }
    }
}
