import AppKit
import EQApeCore
import EQCore
import SwiftUI

/// `--ui-test-control <dir>`: a file-based command channel for agents and scripts (docs/UI-TESTING.md).
///
/// The driver writes `<dir>/cmd/<seq>.json` (atomically: temp file + rename); the app executes the commands one at a
/// time, in name order, and writes `<dir>/res/<seq>.json` (also atomically). `<dir>/app.json` says the channel is ready.
/// No sockets, no OS permissions: UI actions are NSEvents posted into this process's own event queue
/// (`NSApp.postEvent`), aimed at the screen frame of an element found by accessibility identifier in this process's
/// own accessibility tree. Window captures are drawn by AppKit from the live windows (`cacheDisplay`), so they need no
/// Screen Recording permission. Works with and without the engine.
@MainActor
final class UITestControl {
    static let shared = UITestControl()

    private var dir: URL!
    private var cmdDir: URL!
    private var resDir: URL!
    private var timer: DispatchSourceTimer?
    private var busy = false
    private var seen = Set<String>()
    /// The menu being tracked right now (status item menu, context menu, pop-up, pull-down), if any.
    private(set) var trackedMenu: NSMenu?
    private var monitor: Any?
    private var sentinelSeq = 0
    private var sentinelHit = Set<Int>()
    private let started = Date()

    func start(dir path: String) {
        dir = URL(fileURLWithPath: path, isDirectory: true)
        cmdDir = dir.appendingPathComponent("cmd", isDirectory: true)
        resDir = dir.appendingPathComponent("res", isDirectory: true)
        for d in [cmdDir!, resDir!, dir.appendingPathComponent("shots", isDirectory: true)] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { n in
            MainActor.assumeIsolated { UITestControl.shared.trackedMenu = n.object as? NSMenu }
        }
        NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil) { n in
            MainActor.assumeIsolated {
                if UITestControl.shared.trackedMenu === n.object as? NSMenu { UITestControl.shared.trackedMenu = nil }
            }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .applicationDefined) { e in
            if e.subtype.rawValue == 0x5E {
                MainActor.assumeIsolated { _ = UITestControl.shared.sentinelHit.insert(e.data1) }
                return nil
            }
            return e
        }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.2, repeating: 0.03)
        t.setEventHandler { MainActor.assumeIsolated { UITestControl.shared.poll() } }
        t.resume()
        timer = t
        writeJSON(["ready": true, "pid": Int(getpid()), "started": ISO8601DateFormatter().string(from: started),
                   "engineDisabled": AppModel.shared.engineDisabled, "requireGranted": AppModel.shared.options.requireGranted],
                  to: dir.appendingPathComponent("app.json"))
        print("EQ Ape: ui-test control channel ready in \(dir.path)")
        fflush(stdout)
    }

    // MARK: channel

    private func poll() {
        guard !busy, let names = try? FileManager.default.contentsOfDirectory(atPath: cmdDir.path) else { return }
        guard let name = names.filter({ $0.hasSuffix(".json") && !seen.contains($0) }).sorted().first else { return }
        seen.insert(name)
        let url = cmdDir.appendingPathComponent(name)
        let data = (try? Data(contentsOf: url)) ?? Data()
        try? FileManager.default.removeItem(at: url)
        busy = true
        Task { @MainActor in
            var result: [String: Any]
            if let cmd = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                do {
                    result = try await execute(cmd)
                    result["ok"] = result["ok"] ?? true
                    // focus-dependent actions only work while this app is active and its window is key; another app
                    // (a person using the computer) can take that away at any moment
                    result["appActive"] = NSApp.isActive
                    result["keyWindow"] = NSApp.keyWindow.map { self.name(of: $0) } ?? NSNull()
                } catch {
                    result = ["ok": false, "error": "\(error)"]
                }
                result["action"] = cmd["action"] ?? "?"
            } else {
                result = ["ok": false, "error": "not a JSON object"]
            }
            writeJSON(result, to: resDir.appendingPathComponent(name))
            busy = false
        }
    }

    private func writeJSON(_ obj: Any, to url: URL) {
        let d = (try? JSONSerialization.data(withJSONObject: sanitize(obj), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        try? d.write(to: tmp)
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
        if !FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.moveItem(at: tmp, to: url) }
    }

    /// JSON can't hold NaN/inf: replace them with strings.
    private func sanitize(_ v: Any) -> Any {
        switch v {
        case let d as Double: return d.isFinite ? d : (d.isNaN ? "nan" : (d > 0 ? "inf" : "-inf"))
        case let a as [Any]: return a.map(sanitize)
        case let m as [String: Any]: return m.mapValues(sanitize)
        default: return v
        }
    }

    struct Failure: Error, CustomStringConvertible { var description: String }

    // MARK: commands

    func execute(_ c: [String: Any]) async throws -> [String: Any] {
        let action = c["action"] as? String ?? ""
        if ["click", "doubleClick", "rightClick", "drag", "scroll", "key", "type"].contains(action) {
            if let t = c["target"] as? String { try await reveal(t) }
            if let t = c["to"] as? String { try await reveal(t) }
        }
        switch action {
        case "ping":
            return ["pid": Int(getpid())]
        case "state":
            return ["state": state()]
        case "activate":
            NSApp.activate(ignoringOtherApps: true)
            try await settle()
            return ["active": NSApp.isActive]
        case "open":
            let what = c["window"] as? String ?? "editor"
            switch what {
            case "editor": WindowManager.shared.openEditor(path: c["path"] as? String ?? AppModel.shared.options.editorPath)
            case "settings": WindowManager.shared.openSettings()
            case "firstRun": WindowManager.shared.openFirstRun()
            default: throw Failure(description: "unknown window \(what)")
            }
            try await settle(0.4)
            return ["windows": windowList()]
        case "close":
            let what = c["window"] as? String ?? "editor"
            switch what {
            case "editor": WindowManager.shared.closeEditor()
            case "settings": WindowManager.shared.closeSettings()
            case "firstRun": WindowManager.shared.closeFirstRun()
            case "sheet":
                if let w = WindowManager.shared.editorWindow, let s = w.attachedSheet { w.endSheet(s) }
                WindowManager.shared.editorModel?.editingGraphicEQ = nil
            case "popover":
                for w in NSApp.windows where isPopover(w) && w.isVisible { w.close() }
            default: throw Failure(description: "unknown window \(what)")
            }
            try await settle(0.3)
            return ["windows": windowList()]
        case "select":
            guard let m = WindowManager.shared.editorModel else { throw Failure(description: "no editor") }
            let ref = try findRow(m, c)
            m.selection = ref
            m.scrollTarget = ref
            try await settle(0.4)
            return ["selection": EditorModel.rowID(ref)]
        case "move":
            // List drag-reorder through the model's onMove path (a real drag needs the real pointer: see uidrive)
            guard let m = WindowManager.shared.editorModel else { throw Failure(description: "no editor") }
            let ref = try findRow(m, c)
            guard let sec = m.sections.first(where: { $0.url == ref.url }), let from = sec.rows.firstIndex(where: { $0.ref == ref }),
                  let to = c["to"] as? Int else { throw Failure(description: "move needs a row and \"to\" (row index in its file section)") }
            m.move(in: ref.url, from: IndexSet(integer: from), to: to)
            try await settle(0.3)
            return ["selection": m.selection.map(EditorModel.rowID) ?? NSNull()]
        case "click", "doubleClick", "rightClick":
            let (w, p) = try await aimed(c)
            let clicks = action == "doubleClick" ? 2 : (c["clicks"] as? Int ?? 1)
            let hit = w.contentView.flatMap { cv in cv.superview?.hitTest(cv.superview!.convert(p, from: nil)) ?? cv.hitTest(cv.convert(p, from: nil)) }
            try await click(w, p, clicks: clicks, right: action == "rightClick", flags: modifiers(c))
            return ["window": name(of: w), "point": [p.x, p.y], "hitView": hit.map { NSStringFromClass(type(of: $0)) } ?? "none"]
        case "drag":
            let (w, p0) = try await aimed(c)
            var p1 = p0
            if let to = c["to"] as? String {
                let (w2, q) = try target(["target": to])
                guard w2 === w else { throw Failure(description: "drag across windows") }
                p1 = q
            }
            p1.x += CGFloat(c["dx"] as? Double ?? 0)
            p1.y += CGFloat(c["dy"] as? Double ?? 0)   // dy > 0 = up (window coordinates grow upwards); same as uidrive
            try await drag(w, from: p0, to: p1, steps: c["steps"] as? Int ?? 10, flags: modifiers(c))
            return ["window": name(of: w), "from": [p0.x, p0.y], "to": [p1.x, p1.y]]
        case "scroll":
            let (w, p) = try await aimed(c)
            try await scroll(w, p, dy: c["dy"] as? Double ?? 0, dx: c["dx"] as? Double ?? 0, precise: c["precise"] as? Bool ?? false)
            return ["window": name(of: w)]
        case "key":
            if c["target"] != nil { let (w, p) = try await aimed(c); try await click(w, p, clicks: 1, right: false, flags: []) }
            guard let key = c["key"] as? String else { throw Failure(description: "key needs \"key\"") }
            let n = c["repeat"] as? Int ?? 1
            for _ in 0..<n { try postKey(key, flags: modifiers(c)) }
            try await settle()
            return ["firstResponder": firstResponderDescription()]
        case "type":
            var clicksNeeded = 0
            if let t = c["target"] as? String {
                // a person clicks again when the first click only focused the list; record when that was needed
                for _ in 0..<2 where focusedID() != t {
                    let (w, p) = try await aimed(c); try await click(w, p, clicks: 1, right: false, flags: []); clicksNeeded += 1
                }
                if focusedID() != t { throw Failure(description: "\(t) did not take keyboard focus (focus: \(focusedID() ?? "none"))") }
            }
            if c["selectAll"] as? Bool ?? false {
                // what ⌘A does in a field (a synthesised ⌘A is not turned into selectAll: by AppKit; a real one is)
                (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
            }
            for ch in (c["text"] as? String ?? "") { try postKey(String(ch), flags: []) }
            if c["commit"] as? Bool ?? false { try postKey("return", flags: []) }
            try await settle()
            return ["firstResponder": firstResponderDescription(), "clicksToFocus": clicksNeeded]
        case "press":
            // accessibility press action (VoiceOver path), no events
            let e = try element(c["target"] as? String ?? "")
            let ok = e.obj.press()
            try await settle()
            return ["performed": ok]
        case "menu":
            return try await menu(c)
        case "alert":
            return try await alert(c)
        case "wait":
            return try await wait(c)
        case "shot":
            return try shot(c)
        case "tree":
            // debugging aid: roles / identifiers / labels of the accessibility tree, depth-limited
            let w = try window(c["window"] as? String ?? "editor")
            var lines: [String] = []
            func dump(_ o: AnyObject, _ d: Int) {
                let e = AX(obj: o)
                lines.append(String(repeating: "  ", count: d) + "\(e.role ?? "?") id=\(e.identifier ?? "") label=\(e.label ?? "") \(NSStringFromClass(type(of: o)))")
                if d < (c["depth"] as? Int ?? 14) { for k in e.children { dump(k, d + 1) } }
            }
            dump(w, 0)
            return ["tree": lines]
        case "audit":
            return ["missing": audit()]
        case "appearance":
            let a = c["mode"] as? String ?? "system"
            NSApp.appearance = a == "dark" ? NSAppearance(named: .darkAqua) : a == "light" ? NSAppearance(named: .aqua) : nil
            try await settle(0.4)
            return ["appearance": NSApp.effectiveAppearance.name.rawValue]
        case "elements":
            return ["elements": elementList(prefix: c["prefix"] as? String, window: c["window"] as? String)]
        case "resize":
            let w = try window(c["window"] as? String ?? "editor")
            var f = w.frame
            let wd = CGFloat(c["width"] as? Double ?? Double(f.width)), ht = CGFloat(c["height"] as? Double ?? Double(f.height))
            f.origin.y += f.height - ht
            f.size = NSSize(width: wd, height: ht)
            w.setFrame(f, display: true)
            try await settle(0.4)
            return ["frame": rect(w.frame), "content": rect(w.contentLayoutRect)]
        case "quit":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                MainActor.assumeIsolated { AppModel.shared.shutdown() }
                exit(0)
            }
            return ["quitting": true]
        default:
            throw Failure(description: "unknown action \(action)")
        }
    }

    // MARK: targets

    struct Found { var obj: AX; var id: String; var frame: NSRect; var window: NSWindow? }

    /// Dynamic access to the informal NSAccessibility methods of any object in the tree (NSView, NSWindow,
    /// NSAccessibilityElement, SwiftUI's accessibility nodes).
    struct AX {
        let obj: AnyObject
        var o: NSObject? { obj as? NSObject }
        func call(_ sel: String) -> Any? {
            guard let o, o.responds(to: Selector(sel)) else { return nil }
            return o.perform(Selector(sel))?.takeUnretainedValue()
        }
        /// Old attribute API (NSOutlineRow and other AppKit proxies only answer this one).
        func attr(_ name: String) -> Any? {
            guard let o, o.responds(to: Selector(("accessibilityAttributeValue:"))) else { return nil }
            return o.perform(Selector(("accessibilityAttributeValue:")), with: name)?.takeUnretainedValue()
        }
        var children: [AnyObject] {
            if let k = call("accessibilityChildren") as? [Any], !k.isEmpty { return k.map { $0 as AnyObject } }
            return (attr("AXChildren") as? [Any])?.map { $0 as AnyObject } ?? []
        }
        var identifier: String? { (call("accessibilityIdentifier") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? attr("AXIdentifier") as? String }
        var label: String? { (call("accessibilityLabel") as? String) ?? attr("AXDescription") as? String }
        var role: String? { (call("accessibilityRole") as? String) ?? attr("AXRole") as? String }
        var value: Any? { call("accessibilityValue") ?? attr("AXValue") }
        var frame: NSRect {
            let sel = Selector(("accessibilityFrame"))
            if let o, o.responds(to: sel) {
                typealias F = @convention(c) (AnyObject, Selector) -> NSRect
                let r = unsafeBitCast(o.method(for: sel), to: F.self)(o, sel)
                if r != .zero { return r }
            }
            if let p = (attr("AXPosition") as? NSValue)?.pointValue, let sz = (attr("AXSize") as? NSValue)?.sizeValue {
                return NSRect(origin: p, size: sz)
            }
            return .zero
        }
        func bool(_ name: String, _ def: Bool) -> Bool {
            let sel = Selector((name))
            guard let o, o.responds(to: sel) else { return def }
            typealias F = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(o.method(for: sel), to: F.self)(o, sel)
        }
        var enabled: Bool { bool("isAccessibilityEnabled", true) }
        func press() -> Bool { bool("accessibilityPerformPress", false) }
    }

    func window(_ name: String) throws -> NSWindow {
        let wm = WindowManager.shared
        let w: NSWindow?
        switch name {
        case "editor": w = wm.editorWindow
        case "settings": w = wm.settingsWindow
        case "firstRun": w = wm.firstRunWindow
        case "sheet": w = NSApp.windows.first { $0.isSheet && $0.isVisible }
        case "alert", "modal": w = NSApp.modalWindow ?? NSApp.windows.first { $0 is NSPanel && $0.isVisible && $0.level == .modalPanel }
        case "popover": w = NSApp.windows.first { isPopover($0) && $0.isVisible }
        case "statusItem": w = NSApp.windows.first { NSStringFromClass(type(of: $0)).contains("StatusBarWindow") }
        default: w = nil
        }
        guard let w else { throw Failure(description: "window \(name) is not open") }
        return w
    }

    func isPopover(_ w: NSWindow) -> Bool { NSStringFromClass(type(of: w)).contains("Popover") }

    func name(of w: NSWindow) -> String {
        let wm = WindowManager.shared
        if w === wm.editorWindow { return "editor" }
        if w === wm.settingsWindow { return "settings" }
        if w === wm.firstRunWindow { return "firstRun" }
        if w.isSheet { return "sheet" }
        if isPopover(w) { return "popover" }
        if w === NSApp.modalWindow { return "alert" }
        if NSStringFromClass(type(of: w)).contains("StatusBarWindow") { return "statusItem" }
        return NSStringFromClass(type(of: w))
    }

    /// Windows searched for elements: sheets, popovers and alerts first (they sit on top), then the rest.
    var searchWindows: [NSWindow] {
        let vis = NSApp.windows.filter { $0.isVisible }
        let top = vis.filter { $0.isSheet || isPopover($0) || $0 === NSApp.modalWindow }
        return top + vis.filter { w in !top.contains { $0 === w } }
    }

    /// Depth-first walk of this process's accessibility tree (the same objects VoiceOver queries).
    func walk(_ root: AnyObject, depth: Int = 0, _ visit: (AX) -> Bool) -> Bool {
        let ax = AX(obj: root)
        if visit(ax) { return true }
        guard depth < 60 else { return false }
        for k in ax.children { if walk(k, depth: depth + 1, visit) { return true } }
        return false
    }

    /// `id`, or `id>label`: the descendant of element `id` whose label or title is `label` (radio buttons of a
    /// picker, segments, a stepper's arrows "Increment"/"Decrement").
    func element(_ spec: String, window wname: String? = nil) throws -> Found {
        if let gt = spec.firstIndex(of: ">") {
            let parent = try element(String(spec[..<gt]), window: wname)
            let want = String(spec[spec.index(after: gt)...])
            var found: Found?
            _ = walk(parent.obj.obj) { e in
                let title = e.call("accessibilityTitle") as? String
                if e.obj !== parent.obj.obj, e.label == want || title == want || (e.value as? String) == want && e.role == "AXRadioButton" {
                    found = Found(obj: e, id: spec, frame: e.frame, window: parent.window); return true
                }
                return false
            }
            guard let f = found else { throw Failure(description: "no child \"\(want)\" under \(spec[..<gt])") }
            return f
        }
        let id = spec
        let wins = try wname.map { [try window($0)] } ?? searchWindows
        for w in wins {
            var found: Found?
            _ = walk(w) { e in
                if e.identifier == id { found = Found(obj: e, id: id, frame: e.frame, window: w); return true }
                return false
            }
            if let f = found { return f }
        }
        throw Failure(description: "no element with accessibility identifier \"\(id)\" (use action \"elements\" to list them)")
    }

    static let interactiveRoles: Set<String> = ["AXButton", "AXCheckBox", "AXSlider", "AXTextField", "AXPopUpButton", "AXRadioGroup",
                                                "AXMenuButton", "AXIncrementor", "AXSwitch", "AXDisclosureTriangle"]

    /// Interactive elements without an accessibility identifier (or with SwiftUI's default image-name identifier).
    func audit() -> [[String: Any]] {
        var out: [[String: Any]] = []
        func visit(_ o: AnyObject, parentID: String?, parentRole: String?, w: NSWindow, depth: Int) {
            let e = AX(obj: o)
            let id = e.identifier ?? ""
            let good = id.contains(".") && !id.hasPrefix("arrow.") && !id.hasPrefix("_NS") && !id.hasPrefix("NS")
            if let r = e.role, UITestControl.interactiveRoles.contains(r), !good {
                // parts of an identified control (split button segments, slider knobs) and scroller parts are covered
                let isPart = parentRole == "AXScrollBar" || (parentID?.contains(".") ?? false) || e.frame.width < 1 || e.frame.height < 1
                if !isPart { out.append(["role": r, "label": e.label ?? "", "id": id, "window": name(of: w), "frame": rect(e.frame)]) }
            }
            guard depth < 60 else { return }
            for k in e.children { visit(k, parentID: good ? id : nil, parentRole: e.role, w: w, depth: depth + 1) }
        }
        for w in searchWindows where !NSStringFromClass(type(of: w)).contains("StatusBar") {
            // the window's own title-bar buttons are AppKit's, not ours
            for k in AX(obj: w).children where !NSStringFromClass(type(of: k)).contains("Theme") {
                visit(k, parentID: nil, parentRole: nil, w: w, depth: 1)
            }
        }
        return out
    }

    /// Identifier of the element that has keyboard focus (SwiftUI reports it on its nodes), else nil.
    func focusedID() -> String? {
        guard let w = NSApp.keyWindow else { return nil }
        var id: String?
        _ = walk(w) { e in
            if e.bool("isAccessibilityFocused", false), let i = e.identifier, !i.isEmpty { id = i; return true }
            return false
        }
        if id == nil, let fe = w.firstResponder as? NSTextView, fe.isFieldEditor, let tf = fe.delegate as? NSView {
            id = AX(obj: tf).identifier
        }
        return id
    }

    func elementList(prefix: String?, window wname: String?) -> [[String: Any]] {
        var out: [[String: Any]] = []
        let wins = (try? wname.map { [try window($0)] } ?? searchWindows) ?? []
        for w in wins {
            _ = walk(w) { e in
                if let id = e.identifier, !id.isEmpty, prefix.map({ id.hasPrefix($0) }) ?? true {
                    var d: [String: Any] = ["id": id, "window": name(of: w), "frame": rect(e.frame)]
                    if let r = e.role { d["role"] = r }
                    if let l = e.label, !l.isEmpty { d["label"] = l }
                    if let v = e.value { d["value"] = "\(v)" }
                    d["enabled"] = e.enabled
                    out.append(d)
                }
                return false
            }
        }
        return out
    }

    /// The window and the window-coordinate point an action aims at: `target` (accessibility identifier, optional
    /// `offset` [dx, dy] in points from the element's centre, or `at`: "left"/"right" edge), or `window` + `point`
    /// (window coordinates, origin bottom-left).
    func target(_ c: [String: Any]) throws -> (NSWindow, NSPoint) {
        if let id = c["target"] as? String {
            if id == "statusItem" {
                let w = try window("statusItem")
                return (w, NSPoint(x: w.frame.width / 2, y: w.frame.height / 2))
            }
            let f = try element(id, window: c["window"] as? String)
            guard let w = f.window else { throw Failure(description: "element has no window") }
            var p = NSPoint(x: f.frame.midX, y: f.frame.midY)
            switch c["at"] as? String {
            case "left": p.x = f.frame.minX + min(8, f.frame.width / 4)
            case "right": p.x = f.frame.maxX - min(8, f.frame.width / 4)
            default: break
            }
            if let o = c["offset"] as? [Double], o.count == 2 { p.x += CGFloat(o[0]); p.y += CGFloat(o[1]) }
            let wp = w.convertPoint(fromScreen: p)
            guard NSRect(origin: .zero, size: w.frame.size).contains(wp) else {
                throw Failure(description: "element \(id) is outside its window (scrolled away?): \(rect(f.frame))")
            }
            return (w, wp)
        }
        let w = try window(c["window"] as? String ?? "editor")
        guard let pt = c["point"] as? [Double], pt.count == 2 else { throw Failure(description: "need \"target\" or \"point\"") }
        return (w, NSPoint(x: pt[0], y: pt[1]))
    }

    /// The visible part of the filter list (its scroll area), in screen coordinates.
    func visibleListRect() -> NSRect? {
        guard let w = WindowManager.shared.editorWindow else { return nil }
        var r: NSRect?
        _ = walk(w) { e in
            if e.role == "AXScrollArea", e.children.contains(where: { AX(obj: $0).identifier == "editor.list" }) { r = e.frame; return true }
            return false
        }
        return r
    }

    /// Before aiming at something inside a list row ("row.<file>:<line>..."), scroll that row into view: a row
    /// scrolled under the list's clip still reports a frame, and a click there would hit whatever covers it.
    func reveal(_ spec: String) async throws {
        guard spec.hasPrefix("row."), let m = WindowManager.shared.editorModel else { return }
        let base = spec.split(separator: ">").first.map(String.init) ?? spec
        guard let colon = base.lastIndex(of: ":") else { return }
        let digits = base[base.index(after: colon)...].prefix { $0.isNumber }
        let stem = String(base[..<colon]) + ":" + digits
        guard let ref = m.sections.flatMap({ $0.rows }).first(where: { EditorModel.rowID($0.ref) == stem })?.ref else { return }
        // wait until the row is inside the list's visible area AND its frame has stopped moving (an animated scroll
        // or a re-layout after an edit can still be running; a click then lands on whatever passes under it)
        var last = NSRect.null
        let t0 = Date()
        var scrolled = 0
        while Date().timeIntervalSince(t0) < 3 {
            guard let vis = visibleListRect(), let f = try? element(base).frame else { return }
            let visible = vis.insetBy(dx: 0, dy: 2).contains(NSPoint(x: f.midX, y: f.midY)) && f.height > 0
            if visible && f == last { return }
            if !visible && scrolled < 3 { m.scrollTarget = ref; scrolled += 1 }
            last = f
            try await Task.sleep(nanoseconds: 120_000_000)
        }
    }

    /// `target(c)`, verified: an accessibility hit test at the point must land on the element (or inside it) before
    /// events are sent. Retries for up to 2 s while frames settle (SwiftUI updates them asynchronously).
    func aimed(_ c: [String: Any]) async throws -> (NSWindow, NSPoint) {
        guard let spec = c["target"] as? String, spec != "statusItem", c["offset"] == nil else { return try target(c) }
        let want = spec.split(separator: ">").last.map(String.init) ?? spec
        let t0 = Date()
        while true {
            let (w, p) = try target(c)
            let screen = w.convertPoint(toScreen: p)
            // text fields: the AppKit view under the point must be a text field (AX frames can run ahead of layout)
            if (try? element(spec).obj.role) == "AXTextField" {
                let root = w.contentView?.superview ?? w.contentView
                let hv = root.flatMap { $0.hitTest($0.convert(p, from: nil)) }
                if hv is NSTextField || hv is NSTextView { return (w, p) }
                if Date().timeIntervalSince(t0) > 2 { return (w, p) }
                try await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            if let root = w.contentView?.superview ?? w.contentView, let hit = root.accessibilityHitTest(screen) {
                // walk up from the hit element: the target or one of its parents/children labelled like it
                var o: AnyObject? = hit as AnyObject
                var depth = 0
                while let cur = o, depth < 12 {
                    let ax = AX(obj: cur)
                    if ax.identifier == spec || ax.label == want || (ax.call("accessibilityTitle") as? String) == want { return (w, p) }
                    o = ax.call("accessibilityParent") as AnyObject?
                    depth += 1
                }
            } else {
                return (w, p)
            }
            if Date().timeIntervalSince(t0) > 2 { return (w, p) }   // aim anyway; the result's hitView tells what was hit
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func findRow(_ m: EditorModel, _ c: [String: Any]) throws -> LineRef {
        let rows = m.sections.flatMap { $0.rows }
        if let id = c["row"] as? String, let r = rows.first(where: { EditorModel.rowID($0.ref) == id }) { return r.ref }
        if let i = c["index"] as? Int, rows.indices.contains(i) { return rows[i].ref }
        if let t = c["match"] as? String, let r = rows.first(where: { $0.text.contains(t) }) { return r.ref }
        throw Failure(description: "row not found (use \"row\": id, \"index\": n or \"match\": text)")
    }

    // MARK: events

    func modifiers(_ c: [String: Any]) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        for m in (c["modifiers"] as? [String] ?? []) {
            switch m {
            case "shift": f.insert(.shift)
            case "option", "alt": f.insert(.option)
            case "command", "cmd": f.insert(.command)
            case "control", "ctrl": f.insert(.control)
            default: break
            }
        }
        return f
    }

    private func mouse(_ type: NSEvent.EventType, _ w: NSWindow, _ p: NSPoint, clicks: Int, flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: clicks,
                           pressure: (type == .leftMouseUp || type == .rightMouseUp) ? 0 : 1)!
    }

    /// Bring the app and the target window forward (synthesised key events go to the key window). The status item
    /// window is never made key.
    private func prepare(_ w: NSWindow) {
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        if !w.isKeyWindow, w.canBecomeKey, !w.isSheet, NSApp.modalWindow == nil, !NSStringFromClass(type(of: w)).contains("StatusBar") {
            w.makeKeyAndOrderFront(nil)
        }
    }

    func click(_ w: NSWindow, _ p: NSPoint, clicks: Int, right: Bool, flags: NSEvent.ModifierFlags) async throws {
        prepare(w)
        for n in 1...max(1, clicks) {
            NSApp.postEvent(mouse(right ? .rightMouseDown : .leftMouseDown, w, p, clicks: n, flags: flags), atStart: false)
            NSApp.postEvent(mouse(right ? .rightMouseUp : .leftMouseUp, w, p, clicks: n, flags: flags), atStart: false)
        }
        try await settle()
    }

    func drag(_ w: NSWindow, from p0: NSPoint, to p1: NSPoint, steps: Int, flags: NSEvent.ModifierFlags) async throws {
        prepare(w)
        NSApp.postEvent(mouse(.leftMouseDown, w, p0, clicks: 1, flags: flags), atStart: false)
        let n = max(1, steps)
        for i in 1...n {
            let t = CGFloat(i) / CGFloat(n)
            NSApp.postEvent(mouse(.leftMouseDragged, w, NSPoint(x: p0.x + (p1.x - p0.x) * t, y: p0.y + (p1.y - p0.y) * t), clicks: 1, flags: flags), atStart: false)
        }
        NSApp.postEvent(mouse(.leftMouseUp, w, p1, clicks: 1, flags: flags), atStart: false)
        try await settle()
    }

    func scroll(_ w: NSWindow, _ p: NSPoint, dy: Double, dx: Double, precise: Bool) async throws {
        prepare(w)
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line, wheelCount: 2,
                               wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else { throw Failure(description: "cannot make a scroll event") }
        // A converted scroll event carries no window, so its locationInWindow is its (flipped) location: aim it in
        // window coordinates and hand it to the window, which hit-tests the view under that point as for a real one.
        let h = NSScreen.screens.first?.frame.height ?? 0
        cg.location = CGPoint(x: p.x, y: h - p.y)
        guard let e = NSEvent(cgEvent: cg) else { throw Failure(description: "cannot convert the scroll event") }
        w.sendEvent(e)
        try await settle()
    }

    static let keyCodes: [String: (UInt16, String)] = [
        "return": (36, "\r"), "enter": (76, "\u{3}"), "tab": (48, "\t"), "space": (49, " "), "escape": (53, "\u{1b}"),
        "delete": (51, "\u{7f}"), "forwardDelete": (117, String(UnicodeScalar(NSDeleteFunctionKey)!)),
        "left": (123, String(UnicodeScalar(NSLeftArrowFunctionKey)!)), "right": (124, String(UnicodeScalar(NSRightArrowFunctionKey)!)),
        "down": (125, String(UnicodeScalar(NSDownArrowFunctionKey)!)), "up": (126, String(UnicodeScalar(NSUpArrowFunctionKey)!)),
        "home": (115, String(UnicodeScalar(NSHomeFunctionKey)!)), "end": (119, String(UnicodeScalar(NSEndFunctionKey)!)),
    ]
    static let letterCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
    ]

    func postKey(_ key: String, flags: NSEvent.ModifierFlags) throws {
        guard let w = NSApp.keyWindow ?? searchWindows.first else { throw Failure(description: "no window for key events") }
        prepare(w)
        var code: UInt16 = 0, chars = key, f = flags
        if let k = UITestControl.keyCodes[key] {
            code = k.0; chars = k.1
            if (123...126).contains(code) { f.formUnion([.numericPad, .function]) }
            if [115, 117, 119].contains(code) { f.insert(.function) }
        } else if key.count == 1, let ch = key.lowercased().first {
            code = UITestControl.letterCodes[ch] ?? 0
            if key != key.lowercased() { f.insert(.shift) }
        } else {
            throw Failure(description: "unknown key \(key)")
        }
        // Built as CGEvents (like hardware events: keyboard type, device flags) and converted, then posted into this
        // process's own queue only (NSApp.postEvent; CGEvent.post would need the Accessibility permission).
        var cgFlags: CGEventFlags = []
        if f.contains(.command) { cgFlags.insert(.maskCommand) }
        if f.contains(.shift) { cgFlags.insert(.maskShift) }
        if f.contains(.option) { cgFlags.insert(.maskAlternate) }
        if f.contains(.control) { cgFlags.insert(.maskControl) }
        if f.contains(.numericPad) { cgFlags.insert(.maskNumericPad) }
        if f.contains(.function) { cgFlags.insert(.maskSecondaryFn) }
        let src = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let cg = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { continue }
            cg.flags = cgFlags
            // typed characters: always the exact character, whatever the keyboard layout maps the key code to
            if UITestControl.keyCodes[key] == nil {
                var u = Array(chars.utf16)
                cg.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
            }
            if let e = NSEvent(cgEvent: cg) { NSApp.postEvent(e, atStart: false) }
        }
    }

    /// Wait until every event posted so far has been handled (a sentinel event behind them), then a little longer
    /// for SwiftUI to update. Runs inside modal loops too (alerts, menus).
    func settle(_ extra: Double = 0.15) async throws {
        sentinelSeq += 1
        let s = sentinelSeq
        if let e = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                      context: nil, subtype: 0x5E, data1: s, data2: 0) {
            NSApp.postEvent(e, atStart: false)
        }
        let t0 = Date()
        while !sentinelHit.contains(s) && Date().timeIntervalSince(t0) < 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        sentinelHit.remove(s)
        try await Task.sleep(nanoseconds: UInt64(extra * 1e9))
    }

    func firstResponderDescription() -> String {
        guard let r = NSApp.keyWindow?.firstResponder else { return "none" }
        if let t = r as? NSTextView, t.isFieldEditor { return "field editor: \"\(t.string)\"" }
        return NSStringFromClass(type(of: r))
    }

    // MARK: menus and alerts

    /// Menus: the status item's menu (`open: "statusItem"`, or no menu open yet), or whatever menu is being tracked
    /// (after a click on a pop-up, pull-down or a right-click). `list` returns the items; `item` picks one by title.
    func menu(_ c: [String: Any]) async throws -> [String: Any] {
        if trackedMenu == nil, (c["open"] as? String ?? "statusItem") == "statusItem" {
            let w = try window("statusItem")
            try await click(w, NSPoint(x: w.frame.width / 2, y: w.frame.height / 2), clicks: 1, right: false, flags: [])
        }
        let t0 = Date()
        while trackedMenu == nil && Date().timeIntervalSince(t0) < 2 { try await Task.sleep(nanoseconds: 20_000_000) }
        guard let menu = trackedMenu else { throw Failure(description: "no menu is open") }
        menu.update()
        let items = menu.items.map { i -> [String: Any] in
            ["title": i.title, "enabled": i.isEnabled, "state": i.state == .on, "separator": i.isSeparatorItem,
             "keyEquivalent": i.keyEquivalent]
        }
        guard let title = c["item"] as? String else {
            if c["keepOpen"] as? Bool != true { menu.cancelTracking() }
            try await settle()
            return ["items": items]
        }
        guard let idx = menu.items.firstIndex(where: { $0.title == title || $0.title.hasPrefix(title) }) else {
            menu.cancelTracking()
            throw Failure(description: "menu has no item \"\(title)\"; items: \(menu.items.map(\.title))")
        }
        guard menu.items[idx].isEnabled else { menu.cancelTracking(); throw Failure(description: "menu item \"\(title)\" is disabled") }
        menu.performActionForItem(at: idx)
        menu.cancelTracking()
        try await settle(0.3)
        return ["picked": menu.items.indices.contains(idx) ? menu.items[idx].title : title, "items": items]
    }

    /// The current alert or modal panel: its texts and buttons; `button` presses one by title.
    func alert(_ c: [String: Any]) async throws -> [String: Any] {
        let t0 = Date()
        while NSApp.modalWindow == nil && Date().timeIntervalSince(t0) < (c["timeout"] as? Double ?? 2) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard let w = NSApp.modalWindow else { throw Failure(description: "no alert or modal panel") }
        var texts: [String] = [], buttons: [NSButton] = []
        func scan(_ v: NSView) {
            if let b = v as? NSButton, !b.title.isEmpty { buttons.append(b) }
            else if let t = v as? NSTextField, !t.stringValue.isEmpty { texts.append(t.stringValue) }
            v.subviews.forEach(scan)
        }
        if let cv = w.contentView { scan(cv) }
        var r: [String: Any] = ["texts": texts, "buttons": buttons.map(\.title), "title": w.title]
        if let shotName = c["shot"] as? String {
            r["shot"] = try self.shot(shotName.contains("/") ? ["path": shotName, "window": "alert"] : ["name": shotName, "window": "alert"])["path"]
        }
        r["class"] = NSStringFromClass(type(of: w))
        if let p = w as? NSSavePanel { r["panel"] = p is NSOpenPanel ? "open" : "save"; if buttons.isEmpty { r["buttons"] = ["Cancel"] } }
        if let title = c["button"] as? String {
            if let b = buttons.first(where: { $0.title == title }) {
                b.performClick(nil)
            } else if title == "Cancel", let p = w as? NSSavePanel {
                p.cancel(nil)   // the panel's own buttons are drawn by a remote view service
            } else {
                throw Failure(description: "no button \"\(title)\"; buttons: \(buttons.map(\.title))")
            }
            try await settle(0.3)
            r["pressed"] = title
        }
        return r
    }

    // MARK: wait

    /// `path` into the state JSON (dots, [n] for arrays) and one of `equals`, `notEquals`, `contains`, `exists`
    /// (true/false), `gt`, `lt`; `timeout` in seconds (default 5).
    func wait(_ c: [String: Any]) async throws -> [String: Any] {
        guard let path = c["path"] as? String else { throw Failure(description: "wait needs \"path\"") }
        let timeout = c["timeout"] as? Double ?? 5
        let t0 = Date()
        var last: Any?
        while true {
            last = UITestControl.lookup(state(), path)
            if UITestControl.matches(last, c) { return ["value": last ?? NSNull(), "waited": Date().timeIntervalSince(t0)] }
            if Date().timeIntervalSince(t0) > timeout {
                return ["ok": false, "error": "timeout after \(timeout) s waiting for \(path)", "value": last ?? NSNull()]
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    static func lookup(_ root: Any, _ path: String) -> Any? {
        var cur: Any? = root
        for part in path.split(separator: ".") {
            var key = String(part)
            var idx: Int?
            if let b = key.firstIndex(of: "["), key.hasSuffix("]") {
                idx = Int(key[key.index(after: b)..<key.index(before: key.endIndex)])
                key = String(key[..<b])
            }
            if !key.isEmpty { cur = (cur as? [String: Any])?[key] }
            if let i = idx { cur = (cur as? [Any]).flatMap { $0.indices.contains(i) ? $0[i] : nil } }
            if cur == nil || cur is NSNull { return nil }
        }
        return cur
    }

    static func matches(_ v: Any?, _ c: [String: Any]) -> Bool {
        func eq(_ a: Any?, _ b: Any?) -> Bool {
            if let x = a as? Double, let y = b as? Double { return abs(x - y) < 1e-9 }
            if let x = a as? Bool, let y = b as? Bool { return x == y }
            if let x = a as? Int, let y = b as? Int { return x == y }
            if let x = a as? NSNumber, let y = b as? NSNumber { return x == y }
            if let x = a as? String, let y = b as? String { return x == y }
            return a == nil && (b == nil || b is NSNull)
        }
        if let e = c["exists"] as? Bool { return (v != nil) == e }
        if c.keys.contains("equals") { return eq(v, c["equals"]) }
        if c.keys.contains("notEquals") { return !eq(v, c["notEquals"]) }
        if let s = c["contains"] as? String {
            if let t = v as? String { return t.contains(s) }
            if let a = v as? [Any] { return a.contains { ($0 as? String)?.contains(s) == true } }
            return false
        }
        if let g = c["gt"] as? Double, let x = (v as? NSNumber)?.doubleValue { return x > g }
        if let l = c["lt"] as? Double, let x = (v as? NSNumber)?.doubleValue { return x < l }
        return v != nil
    }

    // MARK: state

    func rect(_ r: NSRect) -> [Double] { [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)] }

    func windowList() -> [[String: Any]] {
        NSApp.windows.filter { $0.isVisible && !NSStringFromClass(type(of: $0)).contains("StatusBar") }.map { w in
            ["name": name(of: w), "title": w.title, "key": w.isKeyWindow, "frame": rect(w.frame), "sheet": w.attachedSheet != nil]
        }
    }

    func state() -> [String: Any] {
        let app = AppModel.shared
        let st = app.status
        var s: [String: Any] = [:]
        s["app"] = ["pid": Int(getpid()), "active": NSApp.isActive, "engineDisabled": app.engineDisabled,
                    "requireGranted": app.options.requireGranted, "uptime": Date().timeIntervalSince(started),
                    "opened": app.uiTestOpened, "firstResponder": firstResponderDescription(),
                    "focus": focusedID() ?? NSNull(), "appearance": NSApp.effectiveAppearance.name.rawValue]
        var kind = "\(st.state)"
        if let p = kind.firstIndex(of: "(") { kind = String(kind[..<p]) }
        var eng: [String: Any] = ["state": st.state.label, "kind": kind, "touchesAudio": st.state.touchesAudio, "abBypass": st.abBypass,
                                  "rebuilds": st.rebuilds, "reloads": st.reloads, "warnings": st.warnings.count]
        eng["deviceName"] = st.deviceName ?? NSNull()
        eng["deviceUID"] = st.deviceUID ?? NSNull()
        eng["configPath"] = st.configPath ?? NSNull()
        eng["appliedGainDB"] = st.appliedGainDB ?? NSNull()
        eng["sampleRate"] = st.sampleRate ?? NSNull()
        s["engine"] = eng
        s["meters"] = ["inputDB": app.inputDB, "outputDB": app.outputDB, "inputHoldDB": app.inputHoldDB, "outputHoldDB": app.outputHoldDB,
                       "clipped": Int(app.clipped), "clipRecently": app.clipRecently]
        s["permission"] = ["audioCapture": PermissionCheck.capture().rawValue, "microphone": PermissionCheck.microphone().rawValue]
        s["windows"] = windowList()
        var settings: [String: Any] = ["enabled": app.settings.enabled, "launchAtLogin": app.launchAtLogin]
        settings["profiles"] = app.settings.profiles.mapValues { p -> [String: Any] in
            ["deviceName": p.deviceName, "enabled": p.enabled, "configPath": p.configPath ?? NSNull(),
             "headroomEnabled": p.headroomEnabled, "headroomDB": p.headroomDB]
        }
        s["settings"] = settings
        if let menu = trackedMenu { s["menu"] = menu.items.map(\.title) }
        if let w = NSApp.modalWindow { s["modal"] = ["title": w.title, "class": NSStringFromClass(type(of: w))] }
        if let m = WindowManager.shared.editorModel { s["editor"] = editorState(m) }
        return s
    }

    func editorState(_ m: EditorModel) -> [String: Any] {
        let ws = m.session.workspace
        var e: [String: Any] = ["path": m.rootURL.path, "revision": m.revision, "canUndo": ws.canUndo, "canRedo": ws.canRedo,
                                "undoName": ws.undoName ?? NSNull(), "redoName": ws.redoName ?? NSNull(), "undoCount": ws.undoStack.count,
                                "modified": !ws.modifiedSinceOpen.isEmpty, "writeCount": m.session.writeCount,
                                "pending": m.session.pending.count, "lastError": m.session.lastError ?? NSNull(),
                                "notice": m.notice ?? NSNull(), "isLive": m.isLive,
                                "showPreamp": m.showPreamp, "showAntiClip": m.showAntiClip, "showSelected": m.showSelected, "showPeak": m.showPeak,
                                "sheet": m.editingGraphicEQ.map(EditorModel.rowID) ?? NSNull()]
        e["selection"] = m.selection.map { r -> [String: Any] in
            ["id": EditorModel.rowID(r), "file": r.url.lastPathComponent, "line": r.line + 1, "text": m.line(r)?.text ?? ""]
        } ?? NSNull()
        e["geqNode"] = m.geqNode ?? NSNull()
        e["rows"] = m.sections.flatMap { $0.rows }.map { r -> [String: Any] in
            var d: [String: Any] = ["id": EditorModel.rowID(r.ref), "file": r.ref.url.lastPathComponent, "line": r.ref.line + 1,
                                    "text": r.text, "kind": EditorModel.kindName(r.kind)]
            if let c = r.channels { d["channels"] = c }
            if case .command(.filter(let f)) = r.kind { d["enabled"] = f.enabled }
            if let pts = m.geqPoints(r.ref) {
                d["layout"] = m.geqLayout(r.ref).rawValue
                d["nodes"] = pts.map { [$0.freq, $0.gainDB] }
            }
            return d
        }
        e["warnings"] = m.warnings.map { ["text": $0.text, "row": EditorModel.rowID($0.ref)] }
        let p = m.plot
        let useRight = p.channelsDiffer && p.peakRight.dB > p.peakLeft.dB
        let pk = useRight ? p.peakRight : p.peakLeft
        e["plot"] = ["peakDB": pk.dB, "peakFreq": pk.freq, "antiClipDB": p.antiClipDB, "channelsDiffer": p.channelsDiffer,
                     "peakLabel": m.graphData.peakLabel ?? NSNull(), "handles": m.handles.count]
        if let w = WindowManager.shared.editorWindow { e["frame"] = rect(w.frame); e["key"] = w.isKeyWindow }
        return e
    }

    // MARK: window capture

    /// Draws the app's own live windows into one PNG: `window` (editor, settings, firstRun, sheet, popover, alert, or
    /// "all") plus, for a main window, its sheets, popovers and child windows on top, in the current appearance.
    func shot(_ c: [String: Any]) throws -> [String: Any] {
        let wname = c["window"] as? String ?? "editor"
        var wins: [NSWindow]
        if wname == "all" {
            wins = NSApp.windows.filter { $0.isVisible && !NSStringFromClass(type(of: $0)).contains("StatusBar") }
        } else {
            let w = try window(wname)
            wins = [w]
            for o in NSApp.windows where o.isVisible && o !== w {
                if o.sheetParent === w || w.childWindows?.contains(o) == true || (isPopover(o) && o.frame.intersects(w.frame)) { wins.append(o) }
            }
        }
        // back-to-front: NSApp.orderedWindows is front-to-back
        let order = NSApp.orderedWindows
        // windows missing from orderedWindows (popovers, panels) sit on top: draw them last
        wins.sort { (order.firstIndex(of: $0) ?? -1) > (order.firstIndex(of: $1) ?? -1) }
        let union = wins.reduce(NSRect.null) { $0.union($1.frame) }
        guard !union.isNull, union.width > 0 else { throw Failure(description: "nothing to capture") }
        let scale = wins.map(\.backingScaleFactor).max() ?? 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(union.width * scale), pixelsHigh: Int(union.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { throw Failure(description: "no bitmap") }
        rep.size = union.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for w in wins {
            // popovers: their frame view is a vibrancy material that does not render through cacheDisplay, so draw
            // the content on a plain window-background card (marked approximate in docs/UI-TESTING.md)
            let pop = isPopover(w)
            guard let v = pop ? w.contentView : (w.contentView?.superview ?? w.contentView),
                  let r = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: r)
            let img = NSImage(size: v.bounds.size)
            img.addRepresentation(r)
            // the content view's frame is in the (unflipped) frame view's coordinates: its offset inside the window
            let inner = pop ? v.frame.origin : .zero
            let o = NSPoint(x: w.frame.minX + inner.x - union.minX, y: w.frame.minY + inner.y - union.minY)
            let size = pop ? v.bounds.size : w.frame.size
            if pop {
                w.appearance.map { NSAppearance.current = $0 }
                NSColor.windowBackgroundColor.setFill()
                NSBezierPath(roundedRect: NSRect(origin: o, size: size), xRadius: 8, yRadius: 8).fill()
                NSColor.separatorColor.setStroke()
                NSBezierPath(roundedRect: NSRect(origin: o, size: size).insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8).stroke()
                img.draw(in: NSRect(origin: o, size: size), from: .zero, operation: .sourceOver, fraction: 1)
            } else if w.isOpaque == false {
                img.draw(in: NSRect(origin: o, size: size), from: .zero, operation: .sourceOver, fraction: 1)
            } else {
                img.draw(in: NSRect(origin: o, size: size))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { throw Failure(description: "PNG encoding failed") }
        let fileName = (c["name"] as? String ?? "shot").replacingOccurrences(of: "/", with: "_")
        let out = (c["path"] as? String).map { URL(fileURLWithPath: $0) } ?? dir.appendingPathComponent("shots/\(fileName).png")
        try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: out)
        return ["path": out.path, "windows": wins.map { name(of: $0) }, "size": [rep.pixelsWide, rep.pixelsHigh],
                "appearance": NSApp.effectiveAppearance.name.rawValue]
    }
}

extension EditorModel {
    /// Stable accessibility identifier stem of a list row: "row.<file name>:<line number>".
    static func rowID(_ r: LineRef) -> String { "row.\(r.url.lastPathComponent):\(r.line + 1)" }

    static func kindName(_ k: LineKind) -> String {
        switch k {
        case .blank: return "blank"
        case .comment(let c): return c == nil ? "comment" : "commentedCommand"
        case .unknown: return "unknown"
        case .command(let c):
            switch c {
            case .preamp: return "preamp"
            case .filter: return "filter"
            case .graphicEQ: return "graphicEQ"
            case .channel: return "channel"
            case .include: return "include"
            }
        }
    }
}
