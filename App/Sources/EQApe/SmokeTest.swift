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
