import AppKit
import EQApeCore
import EQCore
import SwiftUI

struct GraphHandle: Equatable {
    var ref: LineRef
    var freq: Double
    var gain: Double
    var q: Double
    var enabled: Bool
    var label: String
    /// 0 = left only, 1 = right only, nil = both channels.
    var channel: Int? = nil
}

/// The GraphicEQ line edited on the graph: its nodes (sorted) and how they may move.
struct GEQOverlay: Equatable {
    var ref: LineRef
    var points: [GraphicEQPoint]
    /// Fixed 15/31-band layout: frequencies locked, no adding or removing.
    var locked: Bool
    var selectedNode: Int?
    var editable: Bool
    /// The line is commented out (shown dashed, as if enabled).
    var active: Bool
}

/// Actions on GraphicEQ nodes, shared by the main graph and the inline row graph.
enum GEQAction {
    case select(LineRef, Int?)
    case drag(LineRef, Int, Double, Double, GraphDragPhase)
    case add(LineRef, Double)
    case remove(LineRef, Int)
    /// Nudge: octaves (frequency), dB (gain).
    case nudge(LineRef, Int, Double, Double)
}

/// Drawing and hit-testing of GraphicEQ nodes: numbered rounded squares in purple (peaking/shelf handles are
/// round and blue/orange), so the two kinds of handles cannot be confused in light or dark mode.
enum GEQNodeStyle {
    static var color: NSColor { .systemPurple }

    static func draw(_ points: [GraphicEQPoint], selected: Int?, at pos: (GraphicEQPoint) -> NSPoint, faint: Bool, size: CGFloat = 15) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: size < 15 ? 7.5 : 8.5, weight: .bold)
        for (i, p) in points.enumerated() {
            let c = pos(p)
            let sel = i == selected
            let s = sel ? size + 3 : size
            let r = NSRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s)
            let path = NSBezierPath(roundedRect: r, xRadius: 3.5, yRadius: 3.5)
            if faint {
                NSColor.textBackgroundColor.setFill(); path.fill()
                color.withAlphaComponent(0.45).setStroke(); path.lineWidth = 1; path.stroke()
                continue
            }
            (sel ? NSColor.controlAccentColor : color).setFill()
            path.fill()
            NSColor.textBackgroundColor.setStroke()
            path.lineWidth = 1.2
            path.stroke()
            if sel {
                let ring = NSBezierPath(roundedRect: r.insetBy(dx: -3, dy: -3), xRadius: 5, yRadius: 5)
                NSColor.controlAccentColor.withAlphaComponent(0.45).setStroke(); ring.lineWidth = 2; ring.stroke()
            }
            let t = NSAttributedString(string: "\(i + 1)", attributes: [.font: font, .foregroundColor: NSColor.white])
            let ts = t.size()
            t.draw(at: NSPoint(x: c.x - ts.width / 2, y: c.y - ts.height / 2))
        }
    }

    static func hit(_ points: [GraphicEQPoint], _ pt: NSPoint, at pos: (GraphicEQPoint) -> NSPoint, radius: CGFloat = 10) -> Int? {
        var best: (Int, CGFloat)?
        for (i, p) in points.enumerated() {
            let c = pos(p)
            let d = hypot(c.x - pt.x, c.y - pt.y)
            if d <= radius, d < (best?.1 ?? .infinity) { best = (i, d) }
        }
        return best?.0
    }

    static func readout(_ p: GraphicEQPoint, index: Int) -> String {
        "\(index + 1): " + GraphFormat.freq(p.freq) + String(format: "  %+.1f dB", p.gainDB)
    }
}

/// Mouse/keyboard behaviour for GraphicEQ nodes in a view that maps frequency and dB to points. Drag moves the node
/// (shift: one axis, decided by the larger movement; frequencies locked in fixed layouts); the caller writes the
/// file through the model (one undo step per gesture).
final class GEQNodeDrag {
    var index: Int?
    var start = NSPoint.zero
    var startValues = (freq: 0.0, gain: 0.0)

    func values(for pt: NSPoint, shift: Bool, locked: Bool, octavesPerPoint: Double, dbPerPoint: Double) -> (Double, Double) {
        var dx = Double(pt.x - start.x), dy = Double(start.y - pt.y)
        if shift { if abs(dx) >= abs(dy) { dy = 0 } else { dx = 0 } }
        if locked { dx = 0 }
        return (startValues.freq * pow(2, dx * octavesPerPoint), startValues.gain + dy * dbPerPoint)
    }

    /// Arrow keys / delete for the selected node. Returns true when handled.
    static func key(_ event: NSEvent, overlay: GEQOverlay?, send: (GEQAction) -> Void) -> Bool {
        guard let o = overlay, o.editable, let i = o.selectedNode, o.points.indices.contains(i) else { return false }
        let big = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 51, 117:   // delete, forward delete
            if !o.locked { send(.remove(o.ref, i)) }
            return true
        case 126: send(.nudge(o.ref, i, 0, big ? 1 : 0.5)); return true
        case 125: send(.nudge(o.ref, i, 0, big ? -1 : -0.5)); return true
        case 123: if !o.locked { send(.nudge(o.ref, i, big ? -1.0 / 6 : -1.0 / 24, 0)) }; return true
        case 124: if !o.locked { send(.nudge(o.ref, i, big ? 1.0 / 6 : 1.0 / 24, 0)) }; return true
        case 48:   // tab: next node
            send(.select(o.ref, (i + (big ? o.points.count - 1 : 1)) % o.points.count)); return true
        default: return false
        }
    }
}

struct GraphData {
    var freqs: [Double] = []
    var left: [Double] = []
    /// nil when both channels are the same.
    var right: [Double]?
    var contribution: [Double]?
    var contributionActive = true
    var handles: [GraphHandle] = []
    var selected: LineRef?
    /// Position of the peak marker on the plotted curve, and its text.
    var peak: (freq: Double, dB: Double)?
    var peakLabel: String?
    /// Curves of the other GraphicEQ lines (faint), on `freqs`.
    var geqOthers: [[Double]] = []
    /// The selected GraphicEQ line's curve on `freqs` and its nodes.
    var geqCurve: [Double]?
    var geq: GEQOverlay?
}

enum GraphDragPhase { case began, changed, ended, scroll }

/// The frequency-response graph: log frequency 20 Hz-20 kHz, auto-scaled dB axis (at least ±12 dB), combined or
/// L/R curves, the selected line's own curve, the peak marker, hover read-out and draggable filter handles.
final class ResponseGraphNSView: NSView {
    var data = GraphData() { didSet { if !dragging { updateRange() }; needsDisplay = true; updateAccessibility() } }
    var onSelect: ((LineRef?) -> Void)?
    var onDrag: ((LineRef, Double, Double, Double, GraphDragPhase) -> Void)?
    var onAddFilter: ((Double, Double) -> Void)?
    var onGEQ: ((GEQAction) -> Void)?
    private let nodeDrag = GEQNodeDrag()

    private(set) var dbLow = -12.0, dbHigh = 12.0
    private var hover: NSPoint?
    private var dragging = false
    private var dragRef: LineRef?
    private var dragStart = NSPoint.zero
    private var dragStartValues = (freq: 0.0, gain: 0.0, q: 1.0)
    private var tracking: NSTrackingArea?

    static let fMin = ResponsePlot.minFreq, fMax = ResponsePlot.maxFreq

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Frequency response graph")
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var plotRect: NSRect {
        NSRect(x: bounds.minX + 46, y: bounds.minY + 22, width: max(10, bounds.width - 46 - 14), height: max(10, bounds.height - 22 - 26))
    }

    func x(_ f: Double) -> CGFloat {
        let p = plotRect
        return p.minX + CGFloat(log(max(1, f) / Self.fMin) / log(Self.fMax / Self.fMin)) * p.width
    }
    func freq(atX x: CGFloat) -> Double {
        let p = plotRect
        return Self.fMin * pow(Self.fMax / Self.fMin, Double((x - p.minX) / p.width))
    }
    func y(_ db: Double) -> CGFloat {
        let p = plotRect
        return p.minY + CGFloat((dbHigh - db) / (dbHigh - dbLow)) * p.height
    }
    func db(atY y: CGFloat) -> Double {
        let p = plotRect
        return dbHigh - Double((y - p.minY) / p.height) * (dbHigh - dbLow)
    }

    /// Auto range: multiples of 6 dB around everything drawn, never smaller than ±12 dB.
    private func updateRange() {
        var lo = 0.0, hi = 0.0
        for v in data.left + (data.right ?? []) + (data.contribution ?? []) where v.isFinite { lo = min(lo, v); hi = max(hi, v) }
        for h in data.handles { lo = min(lo, h.gain); hi = max(hi, h.gain) }
        for p in data.geq?.points ?? [] { lo = min(lo, p.gainDB); hi = max(hi, p.gainDB) }
        lo = max(lo, -60); hi = min(hi, 40)
        dbLow = min(-12, (floor((lo - 1.5) / 6)) * 6)
        dbHigh = max(12, (ceil((hi + 1.5) / 6)) * 6)
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let p = plotRect
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        NSColor.controlBackgroundColor.blended(withFraction: 0.0, of: .black)?.setFill()
        p.fill()

        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor]

        // frequency grid: third-octave-ish minor lines, labelled decades and half-decades
        let minor: [Double] = [20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800, 1000, 1250,
                               1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000, 20000]
        let labelled: [Double] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]
        let major: Set<Double> = [100, 1000, 10000]
        for f in minor {
            let xx = x(f)
            let isLab = labelled.contains(f)
            (major.contains(f) ? NSColor.separatorColor.withAlphaComponent(0.9)
             : NSColor.separatorColor.withAlphaComponent(isLab ? 0.6 : 0.3)).setStroke()
            line(from: NSPoint(x: xx, y: p.minY), to: NSPoint(x: xx, y: p.maxY), width: 1)
            if isLab {
                let s = NSAttributedString(string: GraphFormat.freq(f).replacingOccurrences(of: " Hz", with: "")
                    .replacingOccurrences(of: " kHz", with: "k"), attributes: labelAttrs)
                var lx = xx - s.size().width / 2
                lx = min(max(lx, p.minX - 2), p.maxX - s.size().width + 2)
                s.draw(at: NSPoint(x: lx, y: p.maxY + 5))
            }
        }
        let hz = NSAttributedString(string: "Hz", attributes: labelAttrs)
        hz.draw(at: NSPoint(x: p.minX - hz.size().width - 8, y: p.maxY + 5))

        // dB grid
        let span = dbHigh - dbLow
        let step: Double = span <= 30 ? 3 : span <= 60 ? 6 : 12
        var v = ceil(dbLow / step) * step
        while v <= dbHigh + 1e-9 {
            let yy = y(v)
            if abs(v) < 1e-9 {
                NSColor.labelColor.withAlphaComponent(0.55).setStroke()
                line(from: NSPoint(x: p.minX, y: yy), to: NSPoint(x: p.maxX, y: yy), width: 1.2)
            } else {
                NSColor.separatorColor.withAlphaComponent(Int(v) % 6 == 0 ? 0.6 : 0.3).setStroke()
                line(from: NSPoint(x: p.minX, y: yy), to: NSPoint(x: p.maxX, y: yy), width: 1)
            }
            if Int(v) % (step == 3 ? 6 : Int(step)) == 0 {
                let s = NSAttributedString(string: v > 0 ? "+\(Int(v))" : "\(Int(v))", attributes: labelAttrs)
                s.draw(at: NSPoint(x: p.minX - s.size().width - 6, y: yy - s.size().height / 2))
            }
            v += step
        }
        let dbl = NSAttributedString(string: "dB", attributes: labelAttrs)
        dbl.draw(at: NSPoint(x: p.minX - dbl.size().width - 6, y: bounds.minY + 2))

        ctx.saveGState()
        ctx.clip(to: p)

        // selected line's own curve
        if let c = data.contribution, c.count == data.freqs.count {
            let color = NSColor.systemTeal
            let path = curvePath(c)
            let fill = path.copy() as! NSBezierPath
            fill.line(to: NSPoint(x: x(data.freqs.last!), y: y(0)))
            fill.line(to: NSPoint(x: x(data.freqs.first!), y: y(0)))
            fill.close()
            color.withAlphaComponent(data.contributionActive ? 0.16 : 0.08).setFill()
            fill.fill()
            color.withAlphaComponent(0.8).setStroke()
            path.lineWidth = 1.2
            if !data.contributionActive { path.setLineDash([4, 3], count: 2, phase: 0) }
            path.stroke()
        }

        // main curves
        if let r = data.right, r.count == data.freqs.count {
            stroke(curvePath(r), NSColor.systemOrange, 2)
            stroke(curvePath(data.left), NSColor.systemBlue, 2)
        } else if data.left.count == data.freqs.count, !data.left.isEmpty {
            stroke(curvePath(data.left), NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue, 2.2)
        }

        // peak marker
        if let pk = data.peak {
            let px = x(pk.freq), py = y(pk.dB)
            let tri = NSBezierPath()
            tri.move(to: NSPoint(x: px, y: py - 3))
            tri.line(to: NSPoint(x: px - 5, y: py - 12))
            tri.line(to: NSPoint(x: px + 5, y: py - 12))
            tri.close()
            NSColor.systemRed.setFill()
            tri.fill()
        }

        // other GraphicEQ lines (faint) and the selected one's curve and nodes
        for c in data.geqOthers where c.count == data.freqs.count {
            let path = curvePath(c)
            path.setLineDash([3, 3], count: 2, phase: 0)
            stroke(path, GEQNodeStyle.color.withAlphaComponent(0.35), 1)
        }
        if let c = data.geqCurve, c.count == data.freqs.count {
            let path = curvePath(c)
            if data.geq?.active == false { path.setLineDash([4, 3], count: 2, phase: 0) }
            stroke(path, GEQNodeStyle.color.withAlphaComponent(0.9), 1.6)
        }

        // handles
        for h in data.handles {
            let c = NSPoint(x: x(h.freq), y: y(h.gain))
            let sel = h.ref == data.selected
            let r: CGFloat = sel ? 7.5 : 6
            let circle = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            if h.enabled {
                let base: NSColor = h.channel == 1 ? .systemOrange : .systemBlue
                (sel ? (h.channel == 1 ? NSColor.systemOrange : NSColor.controlAccentColor) : base).withAlphaComponent(sel ? 1 : 0.85).setFill()
                circle.fill()
                NSColor.textBackgroundColor.setStroke()
                circle.lineWidth = 1.5
                circle.stroke()
            } else {
                NSColor.textBackgroundColor.setFill(); circle.fill()
                NSColor.secondaryLabelColor.setStroke(); circle.lineWidth = 1.5; circle.stroke()
            }
            if sel {
                let ring = NSBezierPath(ovalIn: NSRect(x: c.x - r - 3, y: c.y - r - 3, width: 2 * r + 6, height: 2 * r + 6))
                NSColor.controlAccentColor.withAlphaComponent(0.45).setStroke()
                ring.lineWidth = 2
                ring.stroke()
            }
        }
        ctx.restoreGState()
        // nodes outside the clip so the end nodes (20 Hz, 20 kHz) are whole; positions clamped to the plot
        if let g = data.geq {
            GEQNodeStyle.draw(g.points, selected: g.selectedNode, at: nodePos, faint: !g.editable)
        }

        // node read-out while dragging
        if let g = data.geq, let i = nodeDrag.index, g.points.indices.contains(i) {
            let text = GEQNodeStyle.readout(g.points[i], index: i)
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                                                        .foregroundColor: GEQNodeStyle.color]
            let s = NSAttributedString(string: text, attributes: attrs)
            let c = nodePos(g.points[i])
            var lx = c.x + 14
            if lx + s.size().width > p.maxX - 4 { lx = c.x - 14 - s.size().width }
            let ly = max(p.minY + 2, min(p.maxY - s.size().height - 2, c.y - s.size().height - 12))
            drawLabelBox(s, at: NSPoint(x: lx, y: ly))
        }

        // peak label (outside the clip so it can use the top margin)
        if let pk = data.peak, let text = data.peakLabel {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .medium), .foregroundColor: NSColor.systemRed]
            let s = NSAttributedString(string: text, attributes: attrs)
            _ = pk
            // fixed place in the top margin, right-aligned, so it never covers the curve
            drawLabelBox(s, at: NSPoint(x: p.maxX - s.size().width - 4, y: bounds.minY + 4))
        }

        // legend for L/R
        if data.right != nil {
            let la: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.systemBlue]
            let ra: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.systemOrange]
            let l = NSAttributedString(string: "— Left", attributes: la), r = NSAttributedString(string: "— Right", attributes: ra)
            let origin = NSPoint(x: p.minX + 8, y: p.minY + 6)
            drawLabelBox(l, at: origin)
            r.draw(at: NSPoint(x: origin.x + l.size().width + 12, y: origin.y))
        }

        // hover read-out
        if let hpt = hover, p.contains(hpt), !data.freqs.isEmpty {
            NSColor.labelColor.withAlphaComponent(0.35).setStroke()
            line(from: NSPoint(x: hpt.x, y: p.minY), to: NSPoint(x: hpt.x, y: p.maxY), width: 1)
            let f = freq(atX: hpt.x)
            var text = GraphFormat.freq(f)
            let lv = value(data.left, f)
            if let r = data.right {
                text += String(format: "   L %+.1f dB   R %+.1f dB", lv, value(r, f))
            } else {
                text += String(format: "   %+.1f dB", lv)
            }
            let cursorDB = db(atY: hpt.y)
            text += String(format: "   (cursor %+.1f dB)", cursorDB)
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                                                        .foregroundColor: NSColor.labelColor]
            let s = NSAttributedString(string: text, attributes: attrs)
            var lx = hpt.x + 10
            if lx + s.size().width > p.maxX - 4 { lx = hpt.x - 10 - s.size().width }
            drawLabelBox(s, at: NSPoint(x: max(p.minX + 2, lx), y: p.maxY - s.size().height - 8))
            let dot = NSBezierPath(ovalIn: NSRect(x: hpt.x - 3, y: y(lv) - 3, width: 6, height: 6))
            NSColor.labelColor.setFill(); dot.fill()
        }

        NSColor.separatorColor.setStroke()
        NSBezierPath(rect: p).stroke()
    }

    private func value(_ c: [Double], _ f: Double) -> Double {
        guard c.count == data.freqs.count, c.count > 1 else { return 0 }
        var lo = 0, hi = c.count - 1
        while hi - lo > 1 { let m = (lo + hi) / 2; if data.freqs[m] <= f { lo = m } else { hi = m } }
        let u = (log(f) - log(data.freqs[lo])) / max(1e-12, log(data.freqs[hi]) - log(data.freqs[lo]))
        return c[lo] * (1 - u) + c[hi] * u
    }

    private func drawLabelBox(_ s: NSAttributedString, at pt: NSPoint) {
        let r = NSRect(x: pt.x - 4, y: pt.y - 1, width: s.size().width + 8, height: s.size().height + 2)
        NSColor.textBackgroundColor.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
        s.draw(at: pt)
    }

    private func curvePath(_ c: [Double]) -> NSBezierPath {
        let path = NSBezierPath()
        for (i, f) in data.freqs.enumerated() {
            let pt = NSPoint(x: x(f), y: y(max(dbLow - 20, min(dbHigh + 20, c[i]))))
            if i == 0 { path.move(to: pt) } else { path.line(to: pt) }
        }
        path.lineJoinStyle = .round
        return path
    }

    private func stroke(_ path: NSBezierPath, _ color: NSColor, _ width: CGFloat) {
        color.setStroke()
        path.lineWidth = width
        path.stroke()
    }

    private func line(from a: NSPoint, to b: NSPoint, width: CGFloat) {
        let p = NSBezierPath()
        p.move(to: a); p.line(to: b)
        p.lineWidth = width
        p.stroke()
    }

    // MARK: interaction

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        hover = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hover = nil
        needsDisplay = true
    }

    func handle(at pt: NSPoint) -> GraphHandle? {
        var best: (GraphHandle, CGFloat)?
        for h in data.handles {
            let d = hypot(x(h.freq) - pt.x, y(h.gain) - pt.y)
            if d <= 10, d < (best?.1 ?? .infinity) { best = (h, d) }
        }
        return best?.0
    }

    func nodePos(_ p: GraphicEQPoint) -> NSPoint {
        let r = plotRect
        return NSPoint(x: x(min(Self.fMax, max(Self.fMin, p.freq))), y: min(r.maxY, max(r.minY, y(p.gainDB))))
    }

    func geqNode(at pt: NSPoint) -> Int? {
        guard let g = data.geq else { return nil }
        return GEQNodeStyle.hit(g.points, pt, at: nodePos)
    }

    /// Point of node `i` of the GraphicEQ overlay (smoke test).
    func geqNodePoint(_ i: Int) -> NSPoint? {
        guard let g = data.geq, g.points.indices.contains(i) else { return nil }
        return nodePos(g.points[i])
    }

    override func keyDown(with event: NSEvent) {
        if !GEQNodeDrag.key(event, overlay: data.geq, send: { self.onGEQ?($0) }) { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let pt = convert(event.locationInWindow, from: nil)
        if let g = data.geq, g.editable {
            if let i = geqNode(at: pt) {
                if event.clickCount == 2 { if !g.locked { onGEQ?(.remove(g.ref, i)) }; return }
                nodeDrag.index = i
                nodeDrag.start = pt
                nodeDrag.startValues = (g.points[i].freq, g.points[i].gainDB)
                dragging = true
                onGEQ?(.select(g.ref, i))
                onGEQ?(.drag(g.ref, i, g.points[i].freq, g.points[i].gainDB, .began))
                return
            }
            if event.clickCount == 2, handle(at: pt) == nil, plotRect.contains(pt) {
                // double-click adds a node on the curve at that frequency (fixed layouts: switch to Variable first)
                if !g.locked { onGEQ?(.add(g.ref, freq(atX: pt.x))) }
                return
            }
            if handle(at: pt) == nil {
                // a click on empty space keeps the GraphicEQ line selected (so a double-click can add a node)
                onGEQ?(.select(g.ref, nil))
                return
            }
        }
        if event.clickCount == 2, handle(at: pt) == nil, plotRect.contains(pt) {
            onAddFilter?(freq(atX: pt.x), db(atY: pt.y))
            return
        }
        guard let h = handle(at: pt) else { onSelect?(nil); return }
        dragging = true
        dragRef = h.ref
        dragStart = pt
        dragStartValues = (h.freq, h.gain, h.q)
        onSelect?(h.ref)
        onDrag?(h.ref, h.freq, h.gain, h.q, .began)
    }

    override func mouseDragged(with event: NSEvent) {
        if let i = nodeDrag.index, let g = data.geq {
            let pt = convert(event.locationInWindow, from: nil)
            let p = plotRect
            let (f, gn) = nodeDrag.values(for: pt, shift: event.modifierFlags.contains(.shift), locked: g.locked,
                                          octavesPerPoint: log2(Self.fMax / Self.fMin) / Double(p.width),
                                          dbPerPoint: (dbHigh - dbLow) / Double(p.height))
            onGEQ?(.drag(g.ref, i, f, gn, .changed))
            needsDisplay = true
            return
        }
        guard dragging, let ref = dragRef else { return }
        let pt = convert(event.locationInWindow, from: nil)
        hover = pt
        var f = dragStartValues.freq, g = dragStartValues.gain, q = dragStartValues.q
        if event.modifierFlags.contains(.option) {
            // option-drag: vertical movement changes Q (up = narrower)
            q = dragStartValues.q * pow(2, Double(dragStart.y - pt.y) / 60)
        } else {
            let p = plotRect
            f = dragStartValues.freq * pow(Self.fMax / Self.fMin, Double((pt.x - dragStart.x) / p.width))
            g = dragStartValues.gain + Double(dragStart.y - pt.y) / Double(p.height) * (dbHigh - dbLow)
        }
        f = min(Self.fMax, max(Self.fMin, f))
        g = min(30, max(-30, g))
        q = min(50, max(0.05, q))
        onDrag?(ref, f, g, q, .changed)
    }

    override func mouseUp(with event: NSEvent) {
        if let i = nodeDrag.index, let g = data.geq {
            nodeDrag.index = nil
            dragging = false
            onGEQ?(.drag(g.ref, i, 0, 0, .ended))
            updateRange()
            needsDisplay = true
            return
        }
        guard dragging, let ref = dragRef else { return }
        dragging = false
        dragRef = nil
        if let h = data.handles.first(where: { $0.ref == ref }) { onDrag?(ref, h.freq, h.gain, h.q, .ended) }
        updateRange()
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if !scroll(at: pt, deltaY: Double(event.scrollingDeltaY), precise: event.hasPreciseScrollingDeltas) {
            super.scrollWheel(with: event)
        }
    }

    /// Scroll over (or near the selected) handle changes its Q. Returns false if no handle is there.
    @discardableResult
    func scroll(at pt: NSPoint, deltaY: Double, precise: Bool) -> Bool {
        let target = handle(at: pt) ?? data.handles.first(where: { $0.ref == data.selected && hypot(x($0.freq) - pt.x, y($0.gain) - pt.y) < 40 })
        guard let h = target, deltaY != 0 else { return false }
        let scale = precise ? 120.0 : 12.0
        let q = min(50, max(0.05, h.q * pow(2, deltaY / scale)))
        onDrag?(h.ref, h.freq, h.gain, q, .scroll)
        return true
    }

    private func updateAccessibility() {
        var parts: [String] = []
        if let l = data.peakLabel { parts.append(l) }
        parts.append("\(data.handles.count) adjustable filters")
        if let g = data.geq { parts.append("graphic EQ with \(g.points.count) nodes\(g.locked ? ", fixed bands" : "")") }
        if data.right != nil { parts.append("left and right channels differ") }
        setAccessibilityValue(parts.joined(separator: ", "))
    }
}

struct ResponseGraph: NSViewRepresentable {
    var data: GraphData
    var onSelect: (LineRef?) -> Void
    var onDrag: (LineRef, Double, Double, Double, GraphDragPhase) -> Void
    var onAddFilter: (Double, Double) -> Void
    var onGEQ: (GEQAction) -> Void = { _ in }

    func makeNSView(context: Context) -> ResponseGraphNSView {
        let v = ResponseGraphNSView(frame: .zero)
        v.data = data
        return v
    }

    func updateNSView(_ v: ResponseGraphNSView, context: Context) {
        v.onSelect = onSelect
        v.onDrag = onDrag
        v.onAddFilter = onAddFilter
        v.onGEQ = onGEQ
        v.data = data
    }
}
