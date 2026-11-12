import AppKit
import EQApeCore
import EQCore
import SwiftUI

/// UI state of the editor window. All edits go through `ConfigEditSession` (undo, live save, backups).
@MainActor
final class EditorModel: ObservableObject {
    struct Row: Identifiable {
        var id: LineRef { ref }
        var ref: LineRef
        var kind: LineKind
        var text: String
        /// "L", "R", "L R" when a Channel line restricts this line; nil for both channels.
        var channels: String?
    }

    struct FileSection: Identifiable {
        var id: URL { url }
        var url: URL
        var title: String
        var depth: Int
        var exists: Bool
        var isCycle: Bool
        var readOnly: Bool
        var rows: [Row]
    }

    struct Warning: Identifiable {
        var id: Int
        var text: String
        var ref: LineRef
    }

    let session: ConfigEditSession
    let app: AppModel
    /// Shown in the header instead of the real path when set (snapshots).
    var displayPathOverride: String?

    @Published private(set) var revision = 0
    @Published var selection: LineRef?
    @Published var showPreamp = true { didSet { recomputePlot() } }
    @Published var showAntiClip = false { didSet { recomputePlot() } }
    @Published var showSelected = true
    @Published var showPeak = true
    @Published var collapsed: Set<URL> = []
    @Published var editingGraphicEQ: LineRef?
    @Published var scrollTarget: LineRef?
    @Published var notice: String?

    private(set) var evaluation: WorkspaceEvaluation
    private(set) var plot: ResponsePlot
    private(set) var sections: [FileSection] = []
    private(set) var warnings: [Warning] = []
    private var scrollEndWork: DispatchWorkItem?

    init(session: ConfigEditSession, app: AppModel) {
        self.session = session
        self.app = app
        evaluation = session.workspace.evaluate()
        plot = ResponsePlot(config: evaluation.result.config, options: ResponsePlot.Options())
        rebuild()
        session.onChange = { [weak self] in self?.rebuild() }
        session.onExternalReload = { [weak self] url in self?.notice = "\(url.lastPathComponent) changed on disk and was reloaded" }
        session.onConflict = { url in
            let a = NSAlert()
            a.messageText = "\(url.lastPathComponent) changed on disk"
            a.informativeText = "It was changed by another program while you had edits that are not saved yet."
            a.addButton(withTitle: "Reload from Disk")
            a.addButton(withTitle: "Keep My Edits")
            return a.runModal() == .alertFirstButtonReturn
        }
    }

    var rootURL: URL { session.workspace.rootURL }

    var displayPath: String {
        displayPathOverride ?? (rootURL.path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: derived data

    func rebuild() {
        let ws = session.workspace
        evaluation = ws.evaluate()
        var secs: [FileSection] = []
        for node in ws.includeTree().flattened {
            let depth = depthOf(node, in: ws.includeTree())
            let doc = ws.document(node.url)
            var rows: [Row] = []
            if let doc, !node.isCycle {
                for (i, l) in doc.lines.enumerated() {
                    if case .blank = l.kind { continue }
                    let ref = LineRef(url: node.url, line: i)
                    var ch: String?
                    if let c = evaluation.lineChannels[ref], c != [0, 1] {
                        ch = c.isEmpty ? "none" : c.map { $0 == 0 ? "L" : "R" }.joined(separator: " ")
                    }
                    rows.append(Row(ref: ref, kind: l.kind, text: l.text.trimmingCharacters(in: .whitespaces), channels: ch))
                }
            }
            // a file reached twice through Includes is listed once
            if secs.contains(where: { $0.url == node.url }) { continue }
            secs.append(FileSection(url: node.url, title: node.url.lastPathComponent, depth: depth, exists: node.exists,
                                    isCycle: node.isCycle, readOnly: doc?.readOnly ?? true, rows: rows))
        }
        sections = secs
        warnings = zip(evaluation.result.warnings, evaluation.warningRefs).enumerated().map {
            Warning(id: $0.offset, text: $0.element.0, ref: $0.element.1)
        }
        recomputePlot()
        revision += 1
    }

    private func depthOf(_ node: IncludeNode, in root: IncludeNode) -> Int {
        func find(_ n: IncludeNode, _ d: Int) -> Int? {
            if n.url == node.url && n.includedFrom == node.includedFrom { return d }
            for c in n.children { if let r = find(c, d + 1) { return r } }
            return nil
        }
        return find(root, 0) ?? 0
    }

    var plotOptions: ResponsePlot.Options {
        var o = ResponsePlot.Options()
        o.includePreamp = showPreamp
        o.includeAntiClip = showAntiClip
        o.headroomDB = profileForThisFile.map { $0.effectiveHeadroomDB } ?? DeviceProfile.defaultHeadroomDB
        o.sampleRate = app.status.sampleRate ?? 48000
        return o
    }

    /// The device profile whose config is this file, if any.
    var profileForThisFile: DeviceProfile? {
        app.settings.profiles.values.first { p in
            p.configPath.map { URL(fileURLWithPath: $0).standardizedFileURL == rootURL } ?? false
        }
    }

    /// True when the running engine plays this config (it is the current device's config or Included by it).
    var isLive: Bool {
        guard !app.engineDisabled, app.status.state == .active, let p = app.status.configPath else { return false }
        let active = Set(IncludeScanner.files(startingAt: URL(fileURLWithPath: p)).map { $0.standardizedFileURL })
        return session.workspace.documents.keys.contains { active.contains($0) }
    }

    func recomputePlot() {
        plot = ResponsePlot(config: evaluation.result.config, options: plotOptions)
        objectWillChange.send()
    }

    func line(_ ref: LineRef) -> ConfigLine? {
        guard let d = session.workspace.document(ref.url), d.lines.indices.contains(ref.line) else { return nil }
        return d.lines[ref.line]
    }

    func filter(_ ref: LineRef) -> FilterLine? {
        if case .filter(let f)? = line(ref)?.anyCommand { return f }
        return nil
    }

    /// Curve of one line on the plot grid (OFF or commented filters are shown as if enabled).
    func contribution(of ref: LineRef) -> (curve: [Double], active: Bool)? {
        guard let l = line(ref), let cmd = l.anyCommand else { return nil }
        let active = l.kind.command != nil
        var stages: [Stage] = []
        switch cmd {
        case .filter(var f):
            let wasOn = f.enabled
            f.enabled = true
            if let s = f.evaluate(line: l.text).spec { stages = [.biquad(s)] }
            return stages.isEmpty ? nil : (ResponsePlot.sum(stages, freqs: plot.freqs, options: plotOptions), active && wasOn)
        case .graphicEQ(let pts): stages = [.graphicEQ(points: pts)]
        case .preamp(let db): stages = [.gain(dB: db)]
        default: return nil
        }
        var o = plotOptions; o.includePreamp = true
        return (ResponsePlot.sum(stages, freqs: plot.freqs, options: o), active)
    }

    /// Draggable handles: active peaking and shelf filters with a frequency and a gain.
    var handles: [GraphHandle] {
        var out: [GraphHandle] = []
        for sec in sections {
            for r in sec.rows {
                guard case .command(.filter(let f)) = r.kind, f.usesGain, let fc = f.freq, let g = f.gainDB else { continue }
                let ch = evaluation.lineChannels[r.ref]
                out.append(GraphHandle(ref: r.ref, freq: fc, gain: g, q: f.q ?? f.bandwidthOct ?? 1, enabled: f.enabled,
                                       label: f.number.map { "\($0)" } ?? "", channel: ch == [0] ? 0 : ch == [1] ? 1 : nil))
            }
        }
        return out
    }

    var graphData: GraphData {
        var d = GraphData()
        d.freqs = plot.freqs
        d.left = plot.left
        d.right = plot.channelsDiffer ? plot.right : nil
        if showSelected, let sel = selection, let c = contribution(of: sel) {
            d.contribution = c.curve
            d.contributionActive = c.active
        }
        d.handles = handles
        d.selected = selection
        if showPeak {
            let useRight = plot.channelsDiffer && plot.peakRight.dB > plot.peakLeft.dB
            let pk = useRight ? plot.peakRight : plot.peakLeft
            let curve = useRight ? plot.right : plot.left
            let shownFreq = max(ResponsePlot.minFreq, min(ResponsePlot.maxFreq, pk.freq))
            d.peak = (shownFreq, plot.value(curve, at: shownFreq))
            var label = String(format: "peak %+.1f dB at %@", pk.dB, GraphFormat.freq(pk.freq))
            if plotOptions.headroomDB != nil { label += String(format: "  →  anti-clip %.2f dB", plot.antiClipDB) }
            d.peakLabel = label
        }
        return d
    }

    // MARK: edits

    func set(_ cmd: ConfigCommand, at ref: LineRef, name: String, coalesce: String? = nil) {
        session.edit(ref.url, name: name, coalesceKey: coalesce) { try $0.setCommand(cmd, at: ref.line) }
    }

    func setFilter(_ f: FilterLine, at ref: LineRef, name: String, coalesce: String? = nil) {
        set(.filter(f), at: ref, name: name, coalesce: coalesce)
    }

    func endGesture() { session.endCoalescing() }

    func toggleEnabled(_ ref: LineRef) {
        guard var f = filter(ref) else { return }
        f.enabled.toggle()
        setFilter(f, at: ref, name: f.enabled ? "Turn Filter On" : "Turn Filter Off")
    }

    func setCommented(_ ref: LineRef, _ commented: Bool) {
        session.edit(ref.url, name: commented ? "Comment Out Line" : "Enable Line") { try $0.setCommented(commented, at: ref.line) }
    }

    func delete(_ ref: LineRef) {
        if selection == ref { selection = nil }
        session.edit(ref.url, name: "Delete Line") { try $0.removeLine(at: ref.line) }
    }

    func move(in url: URL, from source: IndexSet, to destination: Int) {
        guard let sec = sections.first(where: { $0.url == url }), let s = source.first, source.count == 1 else { return }
        let fromLine = sec.rows[s].ref.line
        let targetLine = destination < sec.rows.count ? sec.rows[destination].ref.line : (sec.rows.last?.ref.line ?? 0) + 1
        let to = fromLine < targetLine ? targetLine - 1 : targetLine
        guard to != fromLine else { return }
        session.edit(url, name: "Move Line") { try $0.moveLine(from: fromLine, to: to) }
        selection = LineRef(url: url, line: to)
    }

    /// Add a peaking filter after the selected line (in its file), else at the end of the file that has the most
    /// filters (the root file when it only Includes others).
    func addFilter(freq: Double = 1000, gain: Double = 0, q: Double = 1) {
        let f = FilterLine(type: "PK", freq: GraphFormat.roundFreq(freq), gainDB: (gain * 10).rounded() / 10, q: q)
        let url: URL
        var index: Int?
        if let sel = selection, session.workspace.document(sel.url)?.readOnly == false {
            url = sel.url; index = sel.line + 1
        } else {
            url = sections.filter { !$0.readOnly }.max { a, b in
                a.rows.filter { if case .command(.filter) = $0.kind { return true }; return false }.count <
                b.rows.filter { if case .command(.filter) = $0.kind { return true }; return false }.count
            }?.url ?? rootURL
        }
        var newLine = 0
        session.edit(url, name: "Add Filter") { doc in
            let i = min(index ?? doc.appendIndex, doc.appendIndex)
            try doc.insertCommand(.filter(f), at: i)
            newLine = i
        }
        selection = LineRef(url: url, line: newLine)
        scrollTarget = selection
    }

    func addPreamp() {
        session.edit(rootURL, name: "Add Preamp") { try $0.insertCommand(.preamp(dB: 0), at: 0) }
        selection = LineRef(url: rootURL, line: 0)
    }

    func undo() { session.undo() }
    func redo() { session.redo() }
    func revert() { session.revertToVersionAtOpen() }

    func jump(to ref: LineRef) {
        collapsed.remove(ref.url)
        // a warning on a hidden (blank) line has no row: select the nearest row above
        if let sec = sections.first(where: { $0.url == ref.url }),
           let row = sec.rows.last(where: { $0.ref.line <= ref.line }) {
            selection = row.ref
        } else {
            selection = ref
        }
        scrollTarget = selection
    }

    // MARK: graph interaction

    /// Values the graph reports for components the user did not move are the file's own values, so only the
    /// components that changed are rounded and written (a click never rewrites a line).
    func dragHandle(_ ref: LineRef, freq: Double, gain: Double, q: Double, phase: GraphDragPhase) {
        guard var f = filter(ref) else { return }
        if phase == .began { selection = ref; return }
        if phase == .ended { endGesture(); return }
        let curQ = f.q ?? f.bandwidthOct ?? 1
        if abs(freq - (f.freq ?? 0)) > 1e-9 { f.freq = GraphFormat.roundFreq(freq) }
        if abs(gain - (f.gainDB ?? 0)) > 1e-9 { f.gainDB = (gain * 10).rounded() / 10 }
        if abs(q - curQ) > 1e-9 {
            if f.bandwidthOct != nil { f.bandwidthOct = GraphFormat.roundQ(q) }
            else if f.isShelf && f.q == nil { /* slope-defined shelf: Q does not apply */ }
            else { f.q = GraphFormat.roundQ(q) }
        }
        let key = phase == .scroll ? "scroll-\(ref.url.path)-\(ref.line)" : "graph-\(ref.url.path)-\(ref.line)"
        setFilter(f, at: ref, name: phase == .scroll ? "Change Q" : "Drag Filter", coalesce: key)
        if phase == .scroll {
            scrollEndWork?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.endGesture() }
            scrollEndWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
        }
    }
}

enum GraphFormat {
    static func freq(_ f: Double) -> String {
        if f >= 1000 {
            let k = f / 1000
            return (k == k.rounded() ? String(format: "%.0f", k) : String(format: k < 10 ? "%.2g" : "%.3g", k)) + " kHz"
        }
        return (f < 100 && f != f.rounded() ? String(format: "%.1f", f) : String(format: "%.0f", f)) + " Hz"
    }

    static func roundFreq(_ f: Double) -> Double {
        let step: Double = f < 100 ? 0.1 : f < 1000 ? 1 : f < 10000 ? 10 : 100
        return max(ResponsePlot.minFreq / 2, min(22000, (f / step).rounded() * step))
    }

    static func roundQ(_ q: Double) -> Double {
        let step: Double = q < 1 ? 0.001 : q < 10 ? 0.01 : 0.1
        return max(0.01, min(100, (q / step).rounded() * step))
    }
}
