import AppKit
import EQApeCore
import EQCore
import SwiftUI

/// `--smoke-test` (with `--editor <file>` and `--no-engine`): drives the real editor window in-process with
/// synthesised AppKit events delivered through `NSWindow.sendEvent` (no Accessibility or other permission involved),
/// checks the file on disk after the live-save debounce, then undoes everything. Prints `SMOKE:` lines. The app
/// keeps running afterwards until it is terminated.
@MainActor
enum SmokeTest {
    static func log(_ s: String) { print("SMOKE: \(s)"); fflush(stdout) }

    static func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { step1() } }
    }

    static func findGraph(_ v: NSView) -> ResponseGraphNSView? {
        if let g = v as? ResponseGraphNSView { return g }
        for s in v.subviews { if let g = findGraph(s) { return g } }
        return nil
    }

    static var original = Data()
    static var fileURL: URL?

    static func step1() {
        guard let w = WindowManager.shared.editorWindow, let m = WindowManager.shared.editorModel else { return log("FAIL no editor window") }
        log("editor window visible=\(w.isVisible) frame=\(NSStringFromRect(w.frame)) sections=\(m.sections.count) handles=\(m.handles.count) warnings=\(m.warnings.count)")
        guard let g = findGraph(w.contentView!) else { return log("FAIL graph view not found") }
        guard let h = m.handles.first(where: { $0.enabled }) else { return log("FAIL no draggable handle") }
        fileURL = h.ref.url
        original = (try? Data(contentsOf: h.ref.url)) ?? Data()
        let before = m.line(h.ref)?.text ?? "?"
        let p0 = NSPoint(x: g.x(h.freq), y: g.y(h.gain))
        log("graph \(NSStringFromRect(g.frame)), dB range \(g.dbLow)...\(g.dbHigh); dragging handle \(before.trimmingCharacters(in: .whitespaces)) at view point \(NSStringFromPoint(p0))")
        func ev(_ type: NSEvent.EventType, _ p: NSPoint, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: g.convert(p, to: nil), modifierFlags: flags,
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        w.sendEvent(ev(.leftMouseDown, p0))
        for i in 1...8 { w.sendEvent(ev(.leftMouseDragged, NSPoint(x: p0.x + CGFloat(i) * 6, y: p0.y - CGFloat(i) * 4))) }
        w.sendEvent(ev(.leftMouseUp, NSPoint(x: p0.x + 48, y: p0.y - 32)))
        let after = m.line(h.ref)?.text ?? "?"
        log("after drag (in memory): \(after)  selection=\(m.selection == h.ref)  undo steps=\(m.session.workspace.undoStack.count)")
        // let SwiftUI push the moved handle into the view before the next gestures
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { MainActor.assumeIsolated { stepQ(m, g, w, h, after) } }
    }

    static func stepQ(_ m: EditorModel, _ g: ResponseGraphNSView, _ w: NSWindow, _ h: GraphHandle, _ after: String) {
        func ev(_ type: NSEvent.EventType, _ p: NSPoint, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: g.convert(p, to: nil), modifierFlags: flags,
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        // option-drag changes Q only
        let p1 = NSPoint(x: g.x(m.filter(h.ref)?.freq ?? h.freq), y: g.y(m.filter(h.ref)?.gainDB ?? h.gain))
        w.sendEvent(ev(.leftMouseDown, p1, flags: .option))
        for i in 1...5 { w.sendEvent(ev(.leftMouseDragged, NSPoint(x: p1.x, y: p1.y - CGFloat(i) * 6), flags: .option)) }
        w.sendEvent(ev(.leftMouseUp, NSPoint(x: p1.x, y: p1.y - 30), flags: .option))
        log("after option-drag (Q): \(m.line(h.ref)?.text ?? "?")")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        // scroll wheel over the handle: the view's scroll handler, called with a view point (a synthesised NSEvent
        // without a window carries screen coordinates, so the event path itself is not exercised here)
        let p2 = NSPoint(x: g.x(m.filter(h.ref)?.freq ?? h.freq), y: g.y(m.filter(h.ref)?.gainDB ?? h.gain))
        let hit = g.scroll(at: p2, deltaY: -6, precise: false)
        log("after scroll (Q, handle hit \(hit)): \(m.line(h.ref)?.text ?? "?")")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { MainActor.assumeIsolated { step2(m, h.ref, after) } }
    }

    static func step2(_ m: EditorModel, _ ref: LineRef, _ afterDrag: String) {
        guard let url = fileURL else { return }
        let disk = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let current = m.line(ref)?.text ?? "?"
        log("on disk after 0.7 s: contains edited line = \(disk.contains(current)); writes=\(m.session.writeCount); pending=\(m.session.pending.count)")
        let ev = m.session.workspace.evaluate()
        let fromDisk = ConfigLoader.load(path: m.rootURL.path)
        log("ConfigLoader (engine's loader) sees the same stages as the editor: \(fromDisk.config == ev.result.config)")
        // undo everything (keyboard shortcut path: the Undo button's ⌘Z action)
        while m.session.workspace.canUndo { m.undo() }
        m.session.flush()
        let restored = (try? Data(contentsOf: url)) ?? Data()
        log("after undo of all steps: file bytes equal the original = \(restored == original)")
        m.redo(); m.session.flush()
        log("redo: file differs again = \(((try? Data(contentsOf: url)) ?? Data()) != original)")
        m.undo(); m.session.flush()
        log("undo again: original restored = \(((try? Data(contentsOf: url)) ?? Data()) == original)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { MainActor.assumeIsolated { stepGEQ(m) } }
    }

    static func findRowGraphs(_ v: NSView) -> [GEQRowGraphNSView] {
        var out: [GEQRowGraphNSView] = []
        if let g = v as? GEQRowGraphNSView { out.append(g) }
        for s in v.subviews { out += findRowGraphs(s) }
        return out
    }

    static func mouse(_ w: NSWindow, _ v: NSView, _ type: NSEvent.EventType, _ p: NSPoint, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) {
        w.sendEvent(NSEvent.mouseEvent(with: type, location: v.convert(p, to: nil), modifierFlags: flags,
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil,
                                       eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1)!)
    }

    static var geqOriginal = Data()

    /// GraphicEQ nodes: on the main graph (sideways, vertical, double-click add and remove) and in the inline row
    /// graph (vertical), then file/loader check and undo to the original bytes.
    static func stepGEQ(_ m: EditorModel) {
        guard let w = WindowManager.shared.editorWindow, let g = findGraph(w.contentView!) else { return log("FAIL no graph") }
        guard let ref = m.graphicEQLines.first else { return log("FAIL no GraphicEQ line") }
        geqOriginal = (try? Data(contentsOf: ref.url)) ?? Data()
        let undo0 = m.session.workspace.undoStack.count
        m.selection = ref
        m.scrollTarget = ref
        log("GraphicEQ \(ref.url.lastPathComponent) line \(ref.line + 1): layout \(m.geqLayout(ref).rawValue), \(m.geqPoints(ref)?.count ?? 0) nodes")
        // the row's "Variable" radio does this (no file change)
        m.setGEQLayout(.variable, for: ref)
        log("switched to \(m.geqLayout(ref).rawValue); file unchanged = \(((try? Data(contentsOf: ref.url)) ?? Data()) == geqOriginal)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated {
            guard let p0 = g.geqNodePoint(3) else { return log("FAIL node 4 not on the graph") }
            log("main graph: node 4 \(GEQNodeStyle.readout(m.geqPoints(ref)![3], index: 3)) at \(NSStringFromPoint(p0))")
            // sideways drag (shift: one axis)
            mouse(w, g, .leftMouseDown, p0)
            var t0 = Date()
            for i in 1...10 { mouse(w, g, .leftMouseDragged, NSPoint(x: p0.x + CGFloat(i) * 3, y: p0.y + CGFloat(i % 2)), flags: .shift) }
            let perStep = Date().timeIntervalSince(t0) / 10
            mouse(w, g, .leftMouseUp, NSPoint(x: p0.x + 30, y: p0.y), flags: .shift)
            log(String(format: "after sideways drag: %@ (%.1f ms per drag step incl. plot and anti-clip recompute)", GEQNodeStyle.readout(m.geqPoints(ref)![3], index: 3), perStep * 1000))
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            // vertical drag
            let p1 = g.geqNodePoint(3)!
            mouse(w, g, .leftMouseDown, p1)
            t0 = Date()
            for i in 1...8 { mouse(w, g, .leftMouseDragged, NSPoint(x: p1.x, y: p1.y + CGFloat(i) * 5)) }
            mouse(w, g, .leftMouseUp, NSPoint(x: p1.x, y: p1.y + 40))
            log("after vertical drag: \(GEQNodeStyle.readout(m.geqPoints(ref)![3], index: 3)); peak label: \(m.graphData.peakLabel ?? "-")")
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            // double-click on the curve adds a node, double-click on it removes it
            let before = m.geqPoints(ref)!.count
            let pa = NSPoint(x: g.x(2236), y: g.y(0))   // between the 2 kHz and 2.5 kHz nodes
            mouse(w, g, .leftMouseDown, pa); mouse(w, g, .leftMouseUp, pa)
            mouse(w, g, .leftMouseDown, pa, clicks: 2); mouse(w, g, .leftMouseUp, pa, clicks: 2)
            let added = m.geqPoints(ref)!.count
            log("double-click at 2.24 kHz: nodes \(before) -> \(added), selected node \(m.geqNode.map { "\($0 + 1)" } ?? "-")")
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            if let i = m.geqNode, let pn = g.geqNodePoint(i) {
                mouse(w, g, .leftMouseDown, pn); mouse(w, g, .leftMouseUp, pn)
                mouse(w, g, .leftMouseDown, pn, clicks: 2); mouse(w, g, .leftMouseUp, pn, clicks: 2)
            }
            log("double-click on that node: nodes \(added) -> \(m.geqPoints(ref)!.count)")
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            // inline row graph: vertical drag on node 1
            if let rg = findRowGraphs(w.contentView!).first(where: { $0.overlay?.ref == ref }), let q = rg.nodePoint(0) {
                mouse(w, rg, .leftMouseDown, q)
                for i in 1...6 { mouse(w, rg, .leftMouseDragged, NSPoint(x: q.x, y: q.y - CGFloat(i) * 3)) }
                mouse(w, rg, .leftMouseUp, NSPoint(x: q.x, y: q.y - 18))
                log("row graph drag (node 1 up): \(GEQNodeStyle.readout(m.geqPoints(ref)![0], index: 0))")
            } else {
                log("FAIL inline row graph not found")
            }
            log("undo steps added by the GraphicEQ gestures: \(m.session.workspace.undoStack.count - undo0) (sideways, vertical, add, remove, row drag)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { MainActor.assumeIsolated { stepGEQCheck(m, ref) } }
        } }
    }

    static func stepGEQCheck(_ m: EditorModel, _ ref: LineRef) {
        let disk = (try? String(contentsOf: ref.url, encoding: .utf8)) ?? ""
        let line = m.line(ref)?.text ?? "?"
        if let w = WindowManager.shared.editorWindow, let g = findGraph(w.contentView!) {
            let rg = findRowGraphs(w.contentView!).first(where: { $0.overlay?.ref == ref })
            log("main graph and row graph show the model's points: \(g.data.geq?.points == m.geqPoints(ref)) / \(rg?.overlay?.points == m.geqPoints(ref))")
        }
        log("on disk: \(disk.trimmingCharacters(in: .newlines))")
        log("file contains the edited line = \(disk.contains(line)); pending=\(m.session.pending.count)")
        let fromDisk = ConfigLoader.load(path: m.rootURL.path)
        log("ConfigLoader sees the same stages as the editor: \(fromDisk.config == m.session.workspace.evaluate().result.config)")
        log("GraphicEQ stage from disk equals the editor's points: \(fromDisk.config?.left.contains(.graphicEQ(points: m.geqPoints(ref)!)) == true)")
        while m.session.workspace.canUndo { m.undo() }
        m.session.flush()
        log("after undo of all steps: GraphicEQ file bytes equal the original = \(((try? Data(contentsOf: ref.url)) ?? Data()) == geqOriginal); first file = \(((try? Data(contentsOf: fileURL!)) ?? Data()) == original)")
        // open the band editor sheet and the settings window
        if let geq = m.sections.flatMap({ $0.rows }).first(where: { if case .command(.graphicEQ) = $0.kind { return true }; return false }) {
            m.editingGraphicEQ = geq.ref
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { MainActor.assumeIsolated { step3(m) } }
    }

    static func step3(_ m: EditorModel) {
        let w = WindowManager.shared.editorWindow
        log("band editor sheet attached = \(w?.attachedSheet != nil)")
        if let sheet = w?.attachedSheet { w?.endSheet(sheet) }
        m.editingGraphicEQ = nil
        WindowManager.shared.openSettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            MainActor.assumeIsolated {
                let titles = NSApp.windows.filter { $0.isVisible }.map { $0.title }.filter { !$0.isEmpty }
                log("visible windows: \(titles)")
                log("done; still running until terminated")
            }
        }
    }
}
