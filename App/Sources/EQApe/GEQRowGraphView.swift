import AppKit
import EQApeCore
import EQCore
import SwiftUI

/// The inline graph of one GraphicEQ line in the filter list (like Equalizer APO's Graphic EQ row): its numbered
/// nodes joined by straight segments (the curve EQCore plays: linear in dB over log frequency, flat outside the end
/// nodes), on a log frequency axis 20 Hz-20 kHz and a dB axis of -20...+15 dB (wider when nodes need it). Drag a
/// node vertically always and sideways in Variable mode; double-click adds (empty spot) or removes (node) a node in
/// Variable mode; arrows nudge, Delete removes, Tab selects the next node.
final class GEQRowGraphNSView: NSView {
    var overlay: GEQOverlay? { didSet { if drag.index == nil { updateRange() }; needsDisplay = true; updateAccessibility() } }
    var onGEQ: ((GEQAction) -> Void)?

    private(set) var dbLow = -20.0, dbHigh = 15.0
    private let drag = GEQNodeDrag()
    static let fMin = 20.0, fMax = 20000.0

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Graphic EQ nodes")
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    var plotRect: NSRect {
        NSRect(x: bounds.minX + 30, y: bounds.minY + 8, width: max(10, bounds.width - 30 - 12), height: max(10, bounds.height - 8 - 18))
    }
    func x(_ f: Double) -> CGFloat {
        let p = plotRect
        let ff = min(Self.fMax, max(Self.fMin, f))
        return p.minX + CGFloat(log(ff / Self.fMin) / log(Self.fMax / Self.fMin)) * p.width
    }
    func freq(atX x: CGFloat) -> Double {
        let p = plotRect
        return Self.fMin * pow(Self.fMax / Self.fMin, Double((x - p.minX) / p.width))
    }
    func y(_ db: Double) -> CGFloat {
        let p = plotRect
        return p.minY + CGFloat((dbHigh - db) / (dbHigh - dbLow)) * p.height
    }
    func pos(_ p: GraphicEQPoint) -> NSPoint { NSPoint(x: x(p.freq), y: y(p.gainDB)) }

    func nodePoint(_ i: Int) -> NSPoint? {
        guard let o = overlay, o.points.indices.contains(i) else { return nil }
        return pos(o.points[i])
    }

    private func updateRange() {
        let g = overlay?.points.map(\.gainDB) ?? []
        dbLow = min(-20, floor(((g.min() ?? 0) - 2) / 5) * 5)
        dbHigh = max(15, ceil(((g.max() ?? 0) + 2) / 5) * 5)
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = plotRect
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        let label: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                                                    .foregroundColor: NSColor.secondaryLabelColor]
        // dB grid every 5 dB, labels every 10 dB (and 15)
        var v = ceil(dbLow / 5) * 5
        while v <= dbHigh + 1e-9 {
            let yy = y(v)
            (abs(v) < 1e-9 ? NSColor.labelColor.withAlphaComponent(0.45) : NSColor.separatorColor.withAlphaComponent(0.5)).setStroke()
            let l = NSBezierPath(); l.move(to: NSPoint(x: p.minX, y: yy)); l.line(to: NSPoint(x: p.maxX, y: yy)); l.lineWidth = abs(v) < 1e-9 ? 1 : 0.6; l.stroke()
            if Int(v) % 10 == 0 || v == dbHigh {
                let s = NSAttributedString(string: v > 0 ? "+\(Int(v))" : "\(Int(v))", attributes: label)
                s.draw(at: NSPoint(x: p.minX - s.size().width - 4, y: yy - s.size().height / 2))
            }
            v += 5
        }
        // frequency labels: the band frequencies in a fixed layout, decades otherwise
        let o = overlay
        let fixed = o?.locked == true
        let labelled: [Double] = fixed ? (o?.points.map(\.freq) ?? []) : [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]
        var lastRight = -CGFloat.infinity
        for f in labelled {
            let xx = x(f)
            NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
            let l = NSBezierPath(); l.move(to: NSPoint(x: xx, y: p.minY)); l.line(to: NSPoint(x: xx, y: p.maxY)); l.lineWidth = 0.6; l.stroke()
            let s = NSAttributedString(string: GraphicEQEditor.short(f), attributes: label)
            let lx = min(max(xx - s.size().width / 2, p.minX - 4), p.maxX - s.size().width + 4)
            if lx > lastRight + 3 { s.draw(at: NSPoint(x: lx, y: p.maxY + 3)); lastRight = lx + s.size().width }
        }
        NSColor.separatorColor.setStroke()
        NSBezierPath(rect: p).stroke()

        guard let o else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: p.insetBy(dx: -10, dy: -10)).addClip()
        // the curve: flat before the first node, straight segments, flat after the last node
        if let first = o.points.first, let last = o.points.last {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: p.minX, y: y(first.gainDB)))
            for q in o.points { path.line(to: pos(q)) }
            path.line(to: NSPoint(x: p.maxX, y: y(last.gainDB)))
            path.lineWidth = 1.6
            path.lineJoinStyle = .round
            if !o.active { path.setLineDash([4, 3], count: 2, phase: 0) }
            GEQNodeStyle.color.withAlphaComponent(o.active ? 0.95 : 0.6).setStroke()
            path.stroke()
        }
        GEQNodeStyle.draw(o.points, selected: o.selectedNode, at: pos, faint: !o.editable, size: o.points.count > 20 ? 13 : 15)
        NSGraphicsContext.restoreGraphicsState()
        // read-out while dragging
        if let i = drag.index, o.points.indices.contains(i) {
            let s = NSAttributedString(string: GEQNodeStyle.readout(o.points[i], index: i),
                                       attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold),
                                                    .foregroundColor: GEQNodeStyle.color])
            let c = pos(o.points[i])
            var lx = c.x + 12
            if lx + s.size().width > p.maxX - 2 { lx = c.x - 12 - s.size().width }
            let ly = max(p.minY + 1, min(p.maxY - s.size().height - 1, c.y - s.size().height - 10))
            let r = NSRect(x: lx - 3, y: ly - 1, width: s.size().width + 6, height: s.size().height + 2)
            NSColor.textBackgroundColor.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
            s.draw(at: NSPoint(x: lx, y: ly))
        }
    }

    // MARK: interaction

    override func keyDown(with event: NSEvent) {
        if !GEQNodeDrag.key(event, overlay: overlay, send: { self.onGEQ?($0) }) { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let o = overlay else { return }
        let pt = convert(event.locationInWindow, from: nil)
        let hit = GEQNodeStyle.hit(o.points, pt, at: pos, radius: 9)
        guard o.editable else { onGEQ?(.select(o.ref, hit)); return }
        if event.clickCount == 2 {
            if let i = hit { if !o.locked { onGEQ?(.remove(o.ref, i)) } }
            else if plotRect.contains(pt), !o.locked { onGEQ?(.add(o.ref, freq(atX: pt.x))) }
            return
        }
        guard let i = hit else { onGEQ?(.select(o.ref, nil)); return }
        drag.index = i
        drag.start = pt
        drag.startValues = (o.points[i].freq, o.points[i].gainDB)
        onGEQ?(.select(o.ref, i))
        onGEQ?(.drag(o.ref, i, o.points[i].freq, o.points[i].gainDB, .began))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let i = drag.index, let o = overlay else { return }
        let pt = convert(event.locationInWindow, from: nil)
        let p = plotRect
        let (f, g) = drag.values(for: pt, shift: event.modifierFlags.contains(.shift), locked: o.locked,
                                 octavesPerPoint: log2(Self.fMax / Self.fMin) / Double(p.width),
                                 dbPerPoint: (dbHigh - dbLow) / Double(p.height))
        onGEQ?(.drag(o.ref, i, f, g, .changed))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let i = drag.index, let o = overlay else { return }
        drag.index = nil
        onGEQ?(.drag(o.ref, i, 0, 0, .ended))
        updateRange()
        needsDisplay = true
    }

    private func updateAccessibility() {
        guard let o = overlay else { return }
        var s = "\(o.points.count) nodes, \(o.locked ? "fixed bands" : "variable")"
        if let i = o.selectedNode, o.points.indices.contains(i) { s += ", selected " + GEQNodeStyle.readout(o.points[i], index: i) }
        setAccessibilityValue(s)
    }
}

struct GEQRowGraph: NSViewRepresentable {
    var overlay: GEQOverlay
    var onGEQ: (GEQAction) -> Void

    func makeNSView(context: Context) -> GEQRowGraphNSView {
        let v = GEQRowGraphNSView(frame: .zero)
        v.overlay = overlay
        return v
    }

    func updateNSView(_ v: GEQRowGraphNSView, context: Context) {
        v.onGEQ = onGEQ
        if v.overlay != overlay { v.overlay = overlay }
    }
}
