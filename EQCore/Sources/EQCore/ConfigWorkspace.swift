import Foundation

/// A line in a file of a workspace.
public struct LineRef: Hashable, Sendable {
    public var url: URL
    public var line: Int   // 0-based
    public init(url: URL, line: Int) { self.url = url; self.line = line }
}

/// One file in the Include tree.
public struct IncludeNode: Equatable, Sendable {
    public var url: URL
    /// The Include line that pulls this file in (nil for the root).
    public var includedFrom: LineRef?
    /// Path as written on the Include line ("" for the root).
    public var pathAsWritten: String
    public var exists: Bool
    /// True when this file is already open further up the chain (an Include cycle): not expanded again.
    public var isCycle: Bool
    public var children: [IncludeNode]

    /// Depth-first list of the nodes (root first).
    public var flattened: [IncludeNode] { [self] + children.flatMap { $0.flattened } }
}

/// Result of evaluating a workspace: the same `ParseResult` as `APOParser.parse(fileURL:)` on the files as they
/// are in memory, plus where every stage and warning comes from.
public struct WorkspaceEvaluation: Sendable {
    public var result: ParseResult
    /// Source line of each stage in `result.config.left` / `.right` (parallel arrays).
    public var leftOrigins: [LineRef]
    public var rightOrigins: [LineRef]
    /// Channel selection in effect at each command line (first visit), 0 = left, 1 = right.
    public var lineChannels: [LineRef: [Int]]
    /// Source line of each warning (parallel to `result.warnings`).
    public var warningRefs: [LineRef]

    /// The stages a given line contributes to the left and right chains.
    public func stages(of ref: LineRef) -> (left: [Stage], right: [Stage]) {
        let l = zip(result.config.left, leftOrigins).filter { $0.1 == ref }.map { $0.0 }
        let r = zip(result.config.right, rightOrigins).filter { $0.1 == ref }.map { $0.0 }
        return (l, r)
    }
}

/// A root config file plus every file it Includes, as editable `ConfigDocument`s, with undo/redo.
///
/// Included files are separate documents; an edit names the file it changes. Nothing here touches the disk
/// except `init`, `refreshIncludes()` and `reloadFromDisk(_:)` (which read); writing is the caller's job.
public final class ConfigWorkspace {
    public let rootURL: URL
    public private(set) var documents: [URL: ConfigDocument] = [:]
    /// Documents as they were first loaded (for "revert to version at open").
    public private(set) var originals: [URL: ConfigDocument] = [:]

    public struct Change: Equatable {
        public var url: URL
        public var before: ConfigDocument
        public var after: ConfigDocument
    }
    public struct UndoEntry: Equatable {
        public var name: String
        public var changes: [Change]
        var coalesceKey: String?
        var open: Bool
    }
    public private(set) var undoStack: [UndoEntry] = []
    public private(set) var redoStack: [UndoEntry] = []
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoLimit = 500

    /// Loads the root file and (recursively) every existing included file. Throws if the root cannot be read.
    public init(rootURL: URL) throws {
        self.rootURL = rootURL.standardizedFileURL
        let data = try Data(contentsOf: self.rootURL)
        let doc = ConfigDocument(data: data)
        documents[self.rootURL] = doc
        originals[self.rootURL] = doc
        refreshIncludes()
    }

    public static func key(_ url: URL) -> URL { url.standardizedFileURL }

    public func document(_ url: URL) -> ConfigDocument? { documents[ConfigWorkspace.key(url)] }

    public var root: ConfigDocument { documents[rootURL]! }

    // MARK: include tree

    /// Files referenced by the Include lines of `url`'s document, in line order: (line, written path, resolved URL).
    public func includes(of url: URL) -> [(line: Int, path: String, url: URL)] {
        guard let doc = document(url) else { return [] }
        let dir = ConfigWorkspace.key(url).deletingLastPathComponent()
        var out: [(Int, String, URL)] = []
        for (i, l) in doc.lines.enumerated() {
            guard case .command(.include(let rest)) = l.kind else { continue }
            let name = APOParser.State.includeName(rest)
            guard let u = APOParser.State.resolveInclude(name, baseDir: dir) else { continue }
            out.append((i, rest, ConfigWorkspace.key(u)))
        }
        return out
    }

    /// Load files that Include lines now reference but that are not loaded yet. Returns the newly loaded URLs.
    @discardableResult
    public func refreshIncludes() -> [URL] {
        var loaded: [URL] = []
        var visited = Set<URL>()
        func visit(_ u: URL, depth: Int) {
            guard depth < 100, !visited.contains(u) else { return }
            visited.insert(u)
            for inc in includes(of: u) {
                if documents[inc.url] == nil, let data = try? Data(contentsOf: inc.url) {
                    let d = ConfigDocument(data: data)
                    documents[inc.url] = d
                    if originals[inc.url] == nil { originals[inc.url] = d }
                    loaded.append(inc.url)
                }
                if documents[inc.url] != nil { visit(inc.url, depth: depth + 1) }
            }
        }
        visit(rootURL, depth: 0)
        return loaded
    }

    public func includeTree() -> IncludeNode {
        func node(_ u: URL, from: LineRef?, path: String, chain: [URL]) -> IncludeNode {
            let exists = documents[u] != nil
            if chain.contains(u) {
                return IncludeNode(url: u, includedFrom: from, pathAsWritten: path, exists: exists, isCycle: true, children: [])
            }
            let kids = exists ? includes(of: u).map {
                node($0.url, from: LineRef(url: u, line: $0.line), path: $0.path, chain: chain + [u])
            } : []
            return IncludeNode(url: u, includedFrom: from, pathAsWritten: path, exists: exists, isCycle: false, children: kids)
        }
        return node(rootURL, from: nil, path: "", chain: [])
    }

    // MARK: evaluation

    /// Stages and warnings exactly as `APOParser.parse(fileURL: rootURL)` would produce them if the in-memory
    /// documents were on disk.
    public func evaluate() -> WorkspaceEvaluation {
        let state = APOParser.State()
        var leftO: [LineRef] = [], rightO: [LineRef] = []
        var chans: [LineRef: [Int]] = [:]
        var warnRefs: [LineRef] = []
        func run(_ u: URL, depth: Int) {
            guard let doc = documents[u] else { return }
            var current = LineRef(url: u, line: 0)
            func sync() {
                while leftO.count < state.left.count { leftO.append(current) }
                while rightO.count < state.right.count { rightO.append(current) }
                while warnRefs.count < state.warnings.count { warnRefs.append(current) }
            }
            let lines = doc.lines.map { ($0.text, $0.kind) }
            state.parseLines(lines, file: u.lastPathComponent, baseDir: u.deletingLastPathComponent(), depth: depth,
                             onLine: { i in
                                 // attribute everything added by the previous line, then switch to line i
                                 sync()
                                 current = LineRef(url: u, line: i)
                                 if doc.lines[i].kind.command != nil, chans[current] == nil { chans[current] = state.channels }
                             },
                             include: { rest, where_, baseDir, depth in
                                 sync()
                                 let name = APOParser.State.includeName(rest)
                                 if depth >= 100 { state.warnings.append("\(where_): include nesting too deep: \(rest)"); sync(); return }
                                 guard let target = APOParser.State.resolveInclude(name, baseDir: baseDir) else {
                                     state.warnings.append("\(where_): included file cannot be resolved (no base URL): \(rest)"); sync(); return
                                 }
                                 let k = ConfigWorkspace.key(target)
                                 guard self.documents[k] != nil else {
                                     state.warnings.append("\(where_): included file not found: \(rest)"); sync(); return
                                 }
                                 let saved = current
                                 run(k, depth: depth + 1)
                                 current = saved
                             })
            sync()
        }
        run(rootURL, depth: 0)
        return WorkspaceEvaluation(result: state.result(), leftOrigins: leftO, rightOrigins: rightO,
                                   lineChannels: chans, warningRefs: warnRefs)
    }

    // MARK: editing with undo

    /// Apply `change` to the document of `url` as one undoable step. Edits with the same `coalesceKey` that follow
    /// each other (until `endCoalescing()`) merge into one undo step (a slider drag). Returns false if nothing changed
    /// or the edit threw.
    @discardableResult
    public func edit(_ url: URL, name: String = "Edit", coalesceKey: String? = nil,
                     _ change: (inout ConfigDocument) throws -> Void) -> Bool {
        let k = ConfigWorkspace.key(url)
        guard var doc = documents[k] else { return false }
        let before = doc
        do { try change(&doc) } catch { return false }
        guard doc != before else { return false }
        documents[k] = doc
        if let key = coalesceKey, var top = undoStack.last, top.open, top.coalesceKey == key,
           top.changes.count == 1, top.changes[0].url == k {
            top.changes[0].after = doc
            undoStack[undoStack.count - 1] = top
        } else {
            closeTop()
            undoStack.append(UndoEntry(name: name, changes: [Change(url: k, before: before, after: doc)],
                                       coalesceKey: coalesceKey, open: coalesceKey != nil))
            if undoStack.count > undoLimit { undoStack.removeFirst(undoStack.count - undoLimit) }
        }
        redoStack.removeAll()
        refreshIncludes()
        return true
    }

    /// Replace several documents in one undoable step (used by "revert to version at open").
    @discardableResult
    public func replaceDocuments(_ new: [URL: ConfigDocument], name: String) -> Bool {
        var changes: [Change] = []
        for (u, d) in new {
            let k = ConfigWorkspace.key(u)
            guard let before = documents[k], before != d else { continue }
            documents[k] = d
            changes.append(Change(url: k, before: before, after: d))
        }
        guard !changes.isEmpty else { return false }
        closeTop()
        undoStack.append(UndoEntry(name: name, changes: changes.sorted { $0.url.path < $1.url.path }, coalesceKey: nil, open: false))
        redoStack.removeAll()
        refreshIncludes()
        return true
    }

    /// Restore every file to the version that was loaded first (one undoable step). Returns the changed URLs.
    @discardableResult
    public func revertToOriginals() -> [URL] {
        let changed = originals.filter { documents[$0.key] != nil && documents[$0.key] != $0.value }
        replaceDocuments(changed, name: "Revert")
        return Array(changed.keys)
    }

    /// Files whose in-memory document differs from the version loaded first.
    public var modifiedSinceOpen: [URL] { originals.compactMap { documents[$0.key] != $0.value ? $0.key : nil } }

    public func endCoalescing() { closeTop() }

    private func closeTop() {
        if var top = undoStack.last, top.open { top.open = false; undoStack[undoStack.count - 1] = top }
    }

    /// Undo the last step. Returns the URLs whose documents changed (nil if there was nothing to undo).
    @discardableResult
    public func undo() -> [URL]? {
        closeTop()
        guard let e = undoStack.popLast() else { return nil }
        for c in e.changes.reversed() { documents[c.url] = c.before }
        redoStack.append(e)
        refreshIncludes()
        return e.changes.map { $0.url }
    }

    @discardableResult
    public func redo() -> [URL]? {
        guard let e = redoStack.popLast() else { return nil }
        for c in e.changes { documents[c.url] = c.after }
        undoStack.append(e)
        refreshIncludes()
        return e.changes.map { $0.url }
    }

    public var undoName: String? { undoStack.last?.name }
    public var redoName: String? { redoStack.last?.name }

    // MARK: external changes

    /// Re-read a file from disk (it changed outside the editor). Not undoable: undo history that touches this file
    /// is dropped, because it no longer describes the file. Returns false if the file could not be read.
    @discardableResult
    public func reloadFromDisk(_ url: URL) -> Bool {
        let k = ConfigWorkspace.key(url)
        guard let data = try? Data(contentsOf: k) else { return false }
        documents[k] = ConfigDocument(data: data)
        undoStack.removeAll { $0.changes.contains { $0.url == k } }
        redoStack.removeAll { $0.changes.contains { $0.url == k } }
        refreshIncludes()
        return true
    }

    /// Adopt a new "version at open" for a file (after an external reload the user accepted).
    public func resetOriginal(_ url: URL) {
        let k = ConfigWorkspace.key(url)
        if let d = documents[k] { originals[k] = d }
    }
}
