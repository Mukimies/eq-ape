import AppKit
import EQApeCore
import EQCore
import SwiftUI

struct EditorView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            EditorHeader(model: model)
            Divider()
            VSplitView {
                VStack(spacing: 0) {
                    GraphOptionsBar(model: model)
                    ResponseGraph(data: model.graphData,
                                  onSelect: { model.selection = $0; if let r = $0 { model.scrollTarget = r } },
                                  onDrag: { model.dragHandle($0, freq: $1, gain: $2, q: $3, phase: $4) },
                                  onAddFilter: { model.addFilter(freq: $0, gain: $1) },
                                  onGEQ: { model.handleGEQ($0) })
                        .frame(minHeight: 200, idealHeight: 300)
                }
                .frame(minHeight: 230, idealHeight: 330)
                FilterList(model: model)
                    .frame(minHeight: 180)
            }
            Divider()
            StatusStrip(model: model, app: app)
        }
        .frame(minWidth: 960, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: Binding(get: { model.editingGraphicEQ.map { GEQRef(ref: $0) } },
                             set: { model.editingGraphicEQ = $0?.ref })) { item in
            GraphicEQEditor(model: model, ref: item.ref)
        }
    }
}

struct GEQRef: Identifiable { var ref: LineRef; var id: LineRef { ref } }

// MARK: header

struct EditorHeader: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(model.rootURL.lastPathComponent).font(.headline).accessibilityIdentifier("editor.file")
                    if model.isLive {
                        Label("Live", systemImage: "waveform").font(.caption.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.green.opacity(0.2)))
                            .help("The running engine plays this file; every change is heard about half a second later")
                    } else {
                        Text("not the active config").font(.caption).foregroundStyle(.secondary)
                            .help("Changes are saved, but the engine is not playing this file right now")
                    }
                }
                Text(model.displayPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Menu {
                Button("Add Filter (peaking)") { model.addFilter() }
                Divider()
                Button("Add Graphic EQ (variable)") { model.addGraphicEQ(.variable) }
                Button("Add Graphic EQ (15 bands)") { model.addGraphicEQ(.fixed15) }
                Button("Add Graphic EQ (31 bands)") { model.addGraphicEQ(.fixed31) }
            } label: {
                Label("Add", systemImage: "plus")
            } primaryAction: {
                model.addFilter()
            }
            .fixedSize()
            .accessibilityIdentifier("editor.add")
            .help("Add a peaking filter after the selected line; the arrow offers graphic EQ lines (variable, 15 or 31 bands)")
            Divider().frame(height: 20)
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.session.workspace.canUndo)
                .help(model.session.workspace.undoName.map { "Undo \($0) (⌘Z)" } ?? "Undo (⌘Z)")
                .accessibilityLabel("Undo")
                .accessibilityIdentifier("editor.undo")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.session.workspace.canRedo)
                .help(model.session.workspace.redoName.map { "Redo \($0) (⇧⌘Z)" } ?? "Redo (⇧⌘Z)")
                .accessibilityLabel("Redo")
                .accessibilityIdentifier("editor.redo")
            Button("Revert to Version at Open") { model.revert() }
                .disabled(model.session.workspace.modifiedSinceOpen.isEmpty)
                .help("Restore every file to the bytes it had when the editor opened it (undoable)")
                .accessibilityIdentifier("editor.revert")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

struct GraphOptionsBar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 14) {
            if let sel = model.selection, let o = model.geqOverlay(sel) {
                GEQNodeFields(model: model, overlay: o)
            } else {
                Text("Drag a handle: ↔ frequency, ↕ gain, ⌥-drag or scroll: Q. Double-click to add a filter.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Toggle("Preamp", isOn: $model.showPreamp).help("Include Preamp lines in the plotted curve").accessibilityIdentifier("editor.opt.preamp")
            Toggle("Anti-clipping gain", isOn: $model.showAntiClip).help("Include the automatic anti-clipping gain the engine applies").accessibilityIdentifier("editor.opt.antiClip")
            Toggle("Selected line", isOn: $model.showSelected).help("Show the selected line's own curve").accessibilityIdentifier("editor.opt.selected")
            Toggle("Peak", isOn: $model.showPeak).help("Mark the maximum of the whole chain (every filter, the graphic EQ as played), which sets the anti-clipping gain").accessibilityIdentifier("editor.opt.peak")
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }
}

// MARK: list

struct FilterList: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $model.selection) {
                let multi = model.sections.count > 1
                ForEach(model.sections) { sec in
                    Section(isExpanded: Binding(get: { !model.collapsed.contains(sec.url) },
                                                set: { if $0 { model.collapsed.remove(sec.url) } else { model.collapsed.insert(sec.url) } })) {
                        if !sec.exists {
                            Text("File not found").foregroundStyle(.secondary).font(.callout)
                        } else if sec.isCycle {
                            Text("Included again (cycle); shown above").foregroundStyle(.secondary).font(.callout)
                        }
                        ForEach(sec.rows) { row in
                            RowView(model: model, row: row, readOnly: sec.readOnly)
                                .tag(row.ref)
                                .id(row.ref)
                        }
                        .onMove { model.move(in: sec.url, from: $0, to: $1) }
                    } header: {
                        if multi || sec.readOnly {
                            HStack(spacing: 6) {
                                Image(systemName: sec.depth == 0 ? "doc.text" : "arrow.turn.down.right")
                                Text(sec.title).font(.system(size: 12, weight: .semibold))
                                if sec.depth > 0 { Text("included").font(.caption).foregroundStyle(.secondary) }
                                if sec.readOnly && sec.exists { Text("read-only (not valid UTF-8/UTF-16)").font(.caption).foregroundStyle(.orange) }
                            }
                            .padding(.leading, CGFloat(sec.depth) * 14)
                            .accessibilityLabel("File \(sec.title)")
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
            .accessibilityIdentifier("editor.list")
            .environment(\.defaultMinListRowHeight, 26)
            .onDeleteCommand { if let s = model.selection { model.delete(s) } }
            .onAppear { if let s = model.selection { proxy.scrollTo(s, anchor: .center) } }
            .onChange(of: model.scrollTarget) { _, t in
                guard let t else { return }
                withAnimation { proxy.scrollTo(t, anchor: .center) }
                model.scrollTarget = nil
            }
        }
    }
}

struct RowView: View {
    let model: EditorModel
    let row: EditorModel.Row
    let readOnly: Bool

    var body: some View {
        content
            .disabled(readOnly)
            .contextMenu {
                if case .command = row.kind {
                    Button("Comment Out") { model.setCommented(row.ref, true) }
                }
                if case .comment(let c) = row.kind, c != nil {
                    Button("Enable (Remove #)") { model.setCommented(row.ref, false) }
                }
                if case .command(.filter) = row.kind {
                    Button("Turn On/Off") { model.toggleEnabled(row.ref) }
                }
                Divider()
                Button("Delete Line", role: .destructive) { model.delete(row.ref) }
            }
    }

    var rid: String { EditorModel.rowID(row.ref) }

    @ViewBuilder var content: some View {
        switch row.kind {
        case .command(.filter(let f)):
            FilterRowView(model: model, ref: row.ref, f: f, channels: row.channels)
        case .command(.preamp(let db)):
            PreampRowView(model: model, ref: row.ref, db: db, channels: row.channels)
        case .command(.graphicEQ(let pts)):
            GraphicEQRowView(model: model, ref: row.ref, points: pts, channels: row.channels)
        case .command(.channel(let names)):
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2").foregroundStyle(.secondary)
                Text("Applies to: \(names.isEmpty ? "no channel" : names.joined(separator: " "))")
                    .font(.system(size: 12, weight: .semibold))
                Text("(lines below, until the next Channel line)").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("\(rid).label")
        case .command(.include(let path)):
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary)
                Text("Include: \(path)").font(.system(size: 12)).accessibilityIdentifier("\(rid).label")
                if model.session.workspace.includes(of: row.ref.url).first(where: { $0.line == row.ref.line })
                    .map({ model.session.workspace.document($0.url) == nil }) ?? true {
                    Text("not found").font(.caption).foregroundStyle(.orange)
                }
            }
        case .comment(.graphicEQ(let pts)?):
            GraphicEQRowView(model: model, ref: row.ref, points: pts, channels: row.channels, active: false)
        case .comment(let cmd):
            HStack(spacing: 8) {
                Text(row.text).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                    .accessibilityIdentifier("\(rid).text")
                Spacer()
                if cmd != nil {
                    Button("Enable") { model.setCommented(row.ref, false) }
                        .controlSize(.small)
                        .help("Remove the # so Equalizer APO syntax on this line takes effect")
                        .accessibilityLabel("Enable commented line")
                        .accessibilityIdentifier("\(rid).enable")
                }
            }
        case .unknown(let msg):
            HStack(spacing: 6) {
                if msg != nil { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption) }
                Text(row.text).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                    .accessibilityIdentifier("\(rid).text")
            }
            .help(msg ?? "Ignored")
        case .blank:
            EmptyView()
        }
    }
}

struct ChannelBadge: View {
    let channels: String?
    var body: some View {
        if let c = channels {
            Text(c).font(.system(size: 10, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(Color.orange.opacity(0.25)))
                .help("Applies to channel \(c) only")
                .accessibilityLabel("Channel \(c) only")
        }
    }
}

struct FilterRowView: View {
    let model: EditorModel
    let ref: LineRef
    let f: FilterLine
    let channels: String?

    static let types: [(String, String)] = [("PK", "Peak"), ("LSC", "Low shelf"), ("HSC", "High shelf"), ("LS", "Low shelf (corner)"),
                                            ("HS", "High shelf (corner)"), ("LP", "Low-pass"), ("HP", "High-pass"), ("LPQ", "Low-pass (Q)"),
                                            ("HPQ", "High-pass (Q)"), ("BP", "Band-pass"), ("NO", "Notch"), ("AP", "All-pass")]

    private var key: String { "\(ref.url.path)-\(ref.line)" }
    private var rid: String { EditorModel.rowID(ref) }

    func update(_ name: String, coalesce: String?, _ change: (inout FilterLine) -> Void) {
        var g = f
        change(&g)
        model.setFilter(g, at: ref, name: name, coalesce: coalesce.map { "\($0)-\(key)" })
    }

    func changeType(_ t: String) {
        update("Change Type", coalesce: nil) { g in
            g.type = t
            if g.freq == nil { g.freq = 1000 }
            if g.usesGain && g.gainDB == nil { g.gainDB = 0 }
            if g.isShelf { g.bandwidthOct = nil } else { g.slopeDB = nil }
            if ["PK", "PEQ", "Modal", "AP"].contains(t), g.q == nil, g.bandwidthOct == nil { g.q = 1 }
            if ["LPQ", "HPQ"].contains(t), g.q == nil { g.q = 0.7071 }
            if ["NO", "BP"].contains(t), g.q == nil, g.bandwidthOct == nil { g.q = t == "NO" ? 30 : 0.7071 }
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Toggle("On", isOn: Binding(get: { f.enabled }, set: { _ in model.toggleEnabled(ref) }))
                .toggleStyle(.checkbox).labelsHidden()
                .accessibilityLabel("Filter \(f.number.map(String.init) ?? "") on")
                .accessibilityIdentifier("\(rid).on")
            Text(f.number.map { "\($0)" } ?? "–").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)
                .accessibilityIdentifier("\(rid).label")
            Picker("Type", selection: Binding(get: { f.type }, set: { changeType($0) })) {
                ForEach(typeOptions, id: \.0) { t in Text("\(t.0)  \(t.1)").tag(t.0) }
            }
            .labelsHidden().controlSize(.small).frame(width: 128)
            .accessibilityLabel("Filter type")
            .accessibilityIdentifier("\(rid).type")
            if f.isNone {
                Text("Empty filter slot (None). Choose a type to use it.").font(.callout).foregroundStyle(.secondary)
            } else {
                param("Fc") {
                    LogSlider(value: f.freq ?? 1000, range: 10...22000, label: "Frequency",
                              onChange: { v in update("Change Frequency", coalesce: "fc") { $0.freq = GraphFormat.roundFreq(v) } },
                              onEnd: model.endGesture).frame(width: 130).accessibilityIdentifier("\(rid).fc")
                    NumberField(value: f.freq ?? 0, digits: 1, label: "Frequency in Hz") { v in update("Change Frequency", coalesce: nil) { $0.freq = max(1, v) } }
                        .accessibilityIdentifier("\(rid).fc.field")
                    unit("Hz")
                }
                param("Gain") {
                    if f.usesGain || f.type == "BP" && f.gainDB != nil {
                        LinearSlider(value: f.gainDB ?? 0, range: -24...24, label: "Gain",
                                     onChange: { v in update("Change Gain", coalesce: "gain") { $0.gainDB = (v * 10).rounded() / 10 } },
                                     onEnd: model.endGesture).frame(width: 110).accessibilityIdentifier("\(rid).gain")
                        NumberField(value: f.gainDB ?? 0, digits: 2, label: "Gain in dB", width: 52) { v in update("Change Gain", coalesce: nil) { $0.gainDB = v } }
                            .accessibilityIdentifier("\(rid).gain.field")
                        unit("dB")
                    } else {
                        Text("—").foregroundStyle(.tertiary).frame(width: 110 + 52 + 22 + 8, alignment: .leading)
                    }
                }
                if f.isShelf && (f.slopeDB != nil || f.q == nil) {
                    param("Slope") {
                        LinearSlider(value: f.slopeDB ?? 10.8, range: 3...24, label: "Slope",
                                     onChange: { v in update("Change Slope", coalesce: "slope") { $0.slopeDB = (v * 2).rounded() / 2 } },
                                     onEnd: model.endGesture).frame(width: 90).accessibilityIdentifier("\(rid).slope")
                        NumberField(value: f.slopeDB ?? 10.8, digits: 1, label: "Slope in dB per octave", width: 46) { v in update("Change Slope", coalesce: nil) { $0.slopeDB = v } }
                            .accessibilityIdentifier("\(rid).slope.field")
                        unit("dB/oct")
                    }
                } else if f.bandwidthOct != nil && !f.isShelf {
                    param("BW") {
                        LogSlider(value: f.bandwidthOct ?? 1, range: 0.05...10, label: "Bandwidth",
                                  onChange: { v in update("Change Bandwidth", coalesce: "bw") { $0.bandwidthOct = GraphFormat.roundQ(v) } },
                                  onEnd: model.endGesture).frame(width: 90).accessibilityIdentifier("\(rid).bw")
                        NumberField(value: f.bandwidthOct ?? 1, digits: 3, label: "Bandwidth in octaves", width: 46) { v in update("Change Bandwidth", coalesce: nil) { $0.bandwidthOct = max(0.01, v) } }
                            .accessibilityIdentifier("\(rid).bw.field")
                        unit("oct")
                    }
                } else if !["LP", "HP"].contains(f.type) || f.q != nil || f.isShelf {
                    param("Q") {
                        LogSlider(value: f.q ?? (f.isShelf ? 0.707 : 1), range: 0.1...30, label: "Q",
                                  onChange: { v in update("Change Q", coalesce: "q") { $0.q = GraphFormat.roundQ(v) } },
                                  onEnd: model.endGesture).frame(width: 90).accessibilityIdentifier("\(rid).q")
                        NumberField(value: f.q ?? 0, digits: 3, label: "Q", width: 52) { v in update("Change Q", coalesce: nil) { $0.q = max(0.01, v) } }
                            .accessibilityIdentifier("\(rid).q.field")
                    }
                } else {
                    Text("Q 0.707 (Butterworth)").font(.caption).foregroundStyle(.secondary)
                }
            }
            ChannelBadge(channels: channels)
            Spacer(minLength: 4)
            Button { model.delete(ref) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help("Delete this line").accessibilityLabel("Delete filter")
                .accessibilityIdentifier("\(rid).delete")
        }
        .opacity(f.enabled ? 1 : 0.55)
        .padding(.vertical, 1)
    }

    var typeOptions: [(String, String)] {
        var t = FilterRowView.types
        if !t.contains(where: { $0.0 == f.type }) {
            t.insert((f.type, f.type == "PEQ" || f.type == "Modal" ? "Peak" : f.type == "None" ? "None" : ""), at: 0)
        }
        return t
    }

    @ViewBuilder func param<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).frame(width: 30, alignment: .trailing)
            c()
        }
    }

    func unit(_ s: String) -> some View {
        Text(s).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: s.count > 2 ? 34 : 18, alignment: .leading)
    }
}

struct PreampRowView: View {
    let model: EditorModel
    let ref: LineRef
    let db: Double
    let channels: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "dial.low").foregroundStyle(.secondary).frame(width: 44)
            Text("Preamp").font(.system(size: 12, weight: .semibold)).frame(width: 128, alignment: .leading)
                .accessibilityIdentifier("\(EditorModel.rowID(ref)).label")
            LinearSlider(value: db, range: -30...12, label: "Preamp",
                         onChange: { v in model.set(.preamp(dB: (v * 10).rounded() / 10), at: ref, name: "Change Preamp", coalesce: "preamp-\(ref.line)") },
                         onEnd: model.endGesture).frame(width: 240)
                .accessibilityIdentifier("\(EditorModel.rowID(ref)).preamp")
            NumberField(value: db, digits: 2, label: "Preamp in dB", width: 56) { v in model.set(.preamp(dB: v), at: ref, name: "Change Preamp") }
                .accessibilityIdentifier("\(EditorModel.rowID(ref)).preamp.field")
            Text("dB").font(.system(size: 10)).foregroundStyle(.secondary)
            ChannelBadge(channels: channels)
            Spacer()
            Button { model.delete(ref) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel("Delete preamp")
                .accessibilityIdentifier("\(EditorModel.rowID(ref)).delete")
        }
    }
}

struct GraphicEQRowView: View {
    @ObservedObject var model: EditorModel
    let ref: LineRef
    let points: [GraphicEQPoint]
    let channels: String?
    var active = true
    private var rid: String { EditorModel.rowID(ref) }

    var body: some View {
        let layout = model.geqLayout(ref)
        let overlay = model.geqOverlay(ref)
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Toggle(isOn: Binding(get: { active }, set: { model.setCommented(ref, !$0) })) {
                        Image(systemName: "power")
                    }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help(active ? "On: click to comment the line out (#), as Equalizer APO does" : "Off (commented out): click to enable")
                    .accessibilityLabel("Graphic EQ on")
                    .accessibilityIdentifier("\(rid).power")
                    Text("Graphic EQ").font(.system(size: 12, weight: .semibold)).accessibilityIdentifier("\(rid).label")
                    ChannelBadge(channels: channels)
                }
                Picker("Bands", selection: Binding(get: { layout }, set: { model.setGEQLayout($0, for: ref) })) {
                    ForEach(GraphicEQEditing.Layout.allCases, id: \.self) { l in Text(l.title.replacingOccurrences(of: " bands", with: "-band")).tag(l) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .controlSize(.small)
                .disabled(!active)
                .help("15-band and 31-band lock the frequencies to the standard bands; Variable lets you move, add and remove nodes")
                .accessibilityLabel("Band mode")
                .accessibilityIdentifier("\(rid).mode")
                Text("\(points.count) nodes").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Button("Sliders…") { model.selection = ref; model.editingGraphicEQ = ref }
                        .controlSize(.small)
                        .help("Edit the bands with vertical sliders in a sheet")
                        .accessibilityIdentifier("\(rid).sliders")
                    Button { model.delete(ref) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel("Delete graphic EQ")
                        .accessibilityIdentifier("\(rid).delete")
                }
            }
            .frame(width: 118, alignment: .leading)
            if let o = overlay {
                GEQRowGraph(overlay: o, idPrefix: rid, onGEQ: { model.handleGEQ($0) })
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(model.selection == ref ? GEQColor.color.opacity(0.7) : Color.secondary.opacity(0.3),
                                                                     lineWidth: model.selection == ref ? 1.5 : 1))
                    .opacity(active ? 1 : 0.6)
            }
        }
        .padding(.vertical, 4)
    }
}

enum GEQColor { static var color: Color { Color(nsColor: GEQNodeStyle.color) } }

/// Read-out and numeric entry for the selected node of the selected GraphicEQ line (above the main graph).
struct GEQNodeFields: View {
    @ObservedObject var model: EditorModel
    let overlay: GEQOverlay

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.fill").foregroundStyle(GEQColor.color).font(.system(size: 9)).accessibilityHidden(true)
            if let i = overlay.selectedNode, overlay.points.indices.contains(i) {
                let p = overlay.points[i]
                Text("Node \(i + 1) of \(overlay.points.count)").font(.caption.weight(.semibold))
                NumberField(value: p.freq, digits: 2, label: "Node frequency in Hz", width: 64) { model.setGEQNode(overlay.ref, i, freq: $0) }
                    .accessibilityIdentifier("editor.node.freq")
                    .disabled(overlay.locked || !overlay.editable)
                Text("Hz").font(.caption).foregroundStyle(.secondary)
                NumberField(value: p.gainDB, digits: 2, label: "Node gain in dB", width: 52) { model.setGEQNode(overlay.ref, i, gain: $0) }
                    .accessibilityIdentifier("editor.node.gain")
                    .disabled(!overlay.editable)
                Text("dB").font(.caption).foregroundStyle(.secondary)
                if !overlay.locked {
                    Button { model.handleGEQ(.remove(overlay.ref, i)) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .disabled(overlay.points.count <= GraphicEQEditing.minNodes || !overlay.editable)
                        .help("Remove this node (also: double-click it, or Delete)")
                        .accessibilityLabel("Remove node")
                        .accessibilityIdentifier("editor.node.remove")
                }
                Text(overlay.locked ? "fixed bands: ↕ only" : "⇧ one axis · arrows nudge")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text(overlay.locked
                     ? "Graphic EQ (fixed bands): drag a node ↕ for gain. Switch the row to Variable to move, add or remove nodes."
                     : "Graphic EQ: drag a node ↔ frequency ↕ gain (⇧ one axis). Double-click to add a node, double-click a node or press Delete to remove it.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
        }
    }
}

struct MiniCurve: View {
    let points: [GraphicEQPoint]
    var body: some View {
        Canvas { ctx, size in
            let m = max(6, points.map { abs($0.gainDB) }.max() ?? 6)
            var p = Path()
            for i in 0...60 {
                let f = 20 * pow(1000, Double(i) / 60)
                let v = GraphicEQDesigner.interpolateDB(points, f)
                let pt = CGPoint(x: size.width * CGFloat(i) / 60, y: size.height / 2 - CGFloat(v / m) * size.height / 2 * 0.9)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: size.height / 2)); $0.addLine(to: CGPoint(x: size.width, y: size.height / 2)) },
                       with: .color(.secondary.opacity(0.4)), lineWidth: 0.5)
            ctx.stroke(p, with: .color(.accentColor), lineWidth: 1.5)
        }
        .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.08)))
        .accessibilityHidden(true)
    }
}

// MARK: status strip

struct StatusStrip: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var app: AppModel
    @State private var showWarnings = false

    var body: some View {
        let st = app.status
        let active = st.state == EngineState.active
        HStack(spacing: 12) {
            Circle().fill(active ? (st.abBypass ? Color.yellow : Color.green) : Color.secondary.opacity(0.5)).frame(width: 9, height: 9)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(st.deviceName ?? "No output device").font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Text(app.engineDisabled ? "engine disabled (--no-engine)" : st.state.label).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(minWidth: 120, maxWidth: 230, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("editor.status.engine")
            VStack(spacing: 2) {
                LevelMeter(label: "In", db: app.inputDB, peakHold: app.inputHoldDB, clip: false, enabled: active)
                    .accessibilityIdentifier("editor.meter.in")
                LevelMeter(label: "Out", db: app.outputDB, peakHold: app.outputHoldDB, clip: app.clipRecently, enabled: active)
                    .accessibilityIdentifier("editor.meter.out")
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Anti-clip").font(.system(size: 10)).foregroundStyle(.secondary)
                    .help("Lowers the level by the largest boost of the whole EQ (every filter, high-pass included) plus the headroom, so a steady tone at full scale stays below 0 dBFS. It does not make clipping impossible: the EQ's phase shifts can raise short peaks of already loud music by a few dB. The clip light shows when that happens.")
                Text(st.appliedGainDB.map { String(format: "%.2f dB", $0) } ?? (model.profileForThisFile?.headroomEnabled == false ? "off" : "–"))
                    .font(.system(size: 11).monospacedDigit())
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("editor.status.antiClip")
            Toggle(isOn: Binding(get: { st.abBypass }, set: { app.setBypass($0) })) {
                Text(st.abBypass ? "Bypassed (B)" : "EQ on (A)").frame(minWidth: 76)
            }
            .toggleStyle(.button)
            .disabled(!active)
            .help("A/B: play the audio without the EQ while held on. The engine keeps running.")
            .accessibilityLabel("Bypass")
            .accessibilityIdentifier("editor.status.bypass")
            Spacer(minLength: 6)
            if let n = model.notice {
                Text(n).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityIdentifier("editor.status.notice")
                    .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 6) { if model.notice == n { model.notice = nil } } }
            }
            if let err = model.session.lastError {
                Label(err, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red).lineLimit(1)
            }
            Button {
                showWarnings.toggle()
            } label: {
                Label(model.warnings.isEmpty ? "No warnings" : "\(model.warnings.count) warning\(model.warnings.count == 1 ? "" : "s")",
                      systemImage: model.warnings.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
            }
            .disabled(model.warnings.isEmpty)
            .accessibilityIdentifier("editor.status.warnings")
            .popover(isPresented: $showWarnings, arrowEdge: .top) { WarningsList(model: model, dismiss: { showWarnings = false }) }
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct WarningsList: View {
    let model: EditorModel
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Lines that are not converted").font(.headline)
            Text("Click a warning to select its line. REW header lines are expected here.").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.warnings) { w in
                        Button { model.jump(to: w.ref); dismiss() } label: {
                            Text(w.text).font(.system(size: 11, design: .monospaced)).multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("warnings.item.\(w.id + 1)")
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .padding(12)
        .frame(width: 560)
    }
}

// MARK: GraphicEQ band editor

struct GraphicEQEditor: View {
    @ObservedObject var model: EditorModel
    let ref: LineRef
    @State private var selected: Int?
    @Environment(\.dismiss) private var dismiss

    var points: [GraphicEQPoint] { model.geqPoints(ref) ?? [] }

    func write(_ pts: [GraphicEQPoint], coalesce: Bool = false) {
        model.set(.graphicEQ(points: GraphicEQEditing.sorted(pts)), at: ref, name: "Edit Graphic EQ",
                  coalesce: coalesce ? "geq-\(ref.url.path)-\(ref.line)" : nil)
    }

    var body: some View {
        let pts = points
        let layout = model.geqLayout(ref)
        let variable = layout == .variable
        let maxAbs = pts.map { abs($0.gainDB) }.max() ?? 0
        let r = max(12, (ceil((maxAbs + 1) / 3)) * 3)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Graphic EQ").font(.title3.weight(.semibold)).fixedSize()
                Spacer(minLength: 12)
                Picker("Mode", selection: Binding(get: { layout }, set: { if model.setGEQLayout($0, for: ref) { selected = nil } })) {
                    Text("Fixed: 15 bands").tag(GraphicEQEditing.Layout.fixed15)
                    Text("Fixed: 31 bands").tag(GraphicEQEditing.Layout.fixed31)
                    Text("Variable").tag(GraphicEQEditing.Layout.variable)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(minWidth: 260, idealWidth: 330, maxWidth: 330)
                .help("Fixed bands: frequencies locked to the standard bands. Variable: every node's frequency is editable. Converting to fixed bands resamples the curve (asks first).")
                .accessibilityLabel("Band mode")
                .accessibilityIdentifier("geq.mode")
                Button("Flatten") { write(pts.map { GraphicEQPoint(freq: $0.freq, gainDB: 0) }) }
                    .help("Set every band to 0 dB")
                    .fixedSize()
                    .accessibilityIdentifier("geq.flatten")
                Button("Add Band") { addBand() }.disabled(pts.isEmpty || !variable).fixedSize().accessibilityIdentifier("geq.addBand")
                Button("Remove Band") { removeBand() }.disabled(selected == nil || pts.count <= GraphicEQEditing.minNodes || !variable)
                    .fixedSize()
                    .accessibilityIdentifier("geq.removeBand")
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).accessibilityIdentifier("geq.done")
            }
            .fixedSize(horizontal: false, vertical: true)
            // on its own line: next to the controls it was squeezed into a narrow wrapped column (seen in a UI-test shot)
            Text("\(ref.url.lastPathComponent), line \(ref.line + 1) · \(pts.count) bands · changes are saved and heard while you drag")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            GraphicEQCurve(points: pts, range: r, selectedFreq: selected.flatMap { pts.indices.contains($0) ? pts[$0].freq : nil })
                .frame(height: 70)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 2) {
                    ForEach(Array(pts.enumerated()), id: \.offset) { i, p in
                        VStack(spacing: 4) {
                            Text(String(format: "%+.1f", p.gainDB)).font(.system(size: 9).monospacedDigit())
                                .foregroundStyle(p.gainDB == 0 ? .secondary : .primary)
                            VerticalSlider(value: p.gainDB, range: -r...r, label: "\(GraphFormat.freq(p.freq)) band",
                                           selected: selected == i,
                                           onChange: { v in
                                               selected = i
                                               var n = pts; n[i].gainDB = v; write(n, coalesce: true)
                                           },
                                           onEnd: model.endGesture)
                                .frame(width: 26, height: 190)
                                .accessibilityIdentifier("geq.band.\(i + 1)")
                            if variable {
                                NumberField(value: p.freq, digits: 1, label: "Band \(i + 1) frequency in Hz", width: 44) { v in
                                    selected = i
                                    model.setGEQNode(ref, i, freq: v)
                                }
                                .accessibilityIdentifier("geq.band.\(i + 1).freq")
                            } else {
                                Text(GraphicEQEditor.short(p.freq)).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                                    .fixedSize()
                            }
                        }
                        .frame(width: variable ? 48 : 30)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 4).fill(selected == i ? Color.accentColor.opacity(0.12) : .clear))
                        .onTapGesture { selected = i }
                    }
                }
                .padding(.horizontal, 4)
            }
            if let i = selected, pts.indices.contains(i) {
                HStack(spacing: 8) {
                    Text("Selected band:").font(.callout)
                    NumberField(value: pts[i].freq, digits: 2, label: "Band frequency in Hz", width: 70) { v in model.setGEQNode(ref, i, freq: v) }
                        .accessibilityIdentifier("geq.selected.freq")
                        .disabled(!variable)
                    Text("Hz").font(.caption).foregroundStyle(.secondary)
                    NumberField(value: pts[i].gainDB, digits: 2, label: "Band gain in dB", width: 56) { v in model.setGEQNode(ref, i, gain: v) }
                        .accessibilityIdentifier("geq.selected.gain")
                    Text("dB").font(.caption).foregroundStyle(.secondary)
                    if !variable { Text("Frequencies are locked in fixed-band mode.").font(.caption).foregroundStyle(.secondary) }
                }
            } else {
                Text(variable
                     ? "Variable: type a frequency under a slider, or drag the nodes on the graph or in the list row. A frequency stays between its neighbours."
                     : "Fixed bands: click a band to select it. Drag a slider, or use the arrow keys on a focused slider (0.5 dB steps).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(minWidth: 760, idealWidth: 1060, minHeight: 440)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    static func short(_ f: Double) -> String {
        if f >= 1000 { let k = f / 1000; return k == k.rounded() ? String(format: "%.0fk", k) : String(format: "%.3gk", k) }
        return f == f.rounded() ? String(format: "%.0f", f) : String(format: "%.1f", f)
    }

    func addBand() {
        let pts = points
        guard pts.count >= 2 else { return }
        let i = min(selected ?? (pts.count - 2), pts.count - 2)
        let f = (pts[i].freq * pts[i + 1].freq).squareRoot()
        if let r = GraphicEQEditing.addNode(pts, freq: f) {
            model.endGesture()
            write(r.points)
            selected = r.index
        }
    }

    func removeBand() {
        guard let i = selected, let n = GraphicEQEditing.removeNode(points, index: i) else { return }
        model.endGesture()
        write(n)
        selected = nil
    }
}

struct GraphicEQCurve: View {
    let points: [GraphicEQPoint]
    let range: Double
    let selectedFreq: Double?
    var body: some View {
        Canvas { ctx, size in
            func x(_ f: Double) -> CGFloat { size.width * CGFloat(log(f / 20) / log(1000)) }
            func y(_ v: Double) -> CGFloat { size.height / 2 - CGFloat(v / range) * size.height / 2 }
            ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y(0))); $0.addLine(to: CGPoint(x: size.width, y: y(0))) },
                       with: .color(.secondary.opacity(0.5)), lineWidth: 0.5)
            var p = Path()
            for i in 0...200 {
                let f = 20 * pow(1000, Double(i) / 200)
                let pt = CGPoint(x: x(f), y: y(GraphicEQDesigner.interpolateDB(points, f)))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            ctx.stroke(p, with: .color(.accentColor), lineWidth: 2)
            for pt in points where pt.freq >= 20 && pt.freq <= 20000 {
                let c = CGPoint(x: x(pt.freq), y: y(pt.gainDB))
                let r: CGFloat = pt.freq == selectedFreq ? 4 : 2.5
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(.accentColor))
            }
        }
        .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
        .accessibilityLabel("Graphic EQ curve")
    }
}
