// eqape-uidrive: real input and real pixels for EQ Ape's dev instance (docs/UI-TESTING.md). Run via App/scripts/uidrive.
//
//   uidrive perms                              which OS permissions this terminal has (never prompts)
//   uidrive tree [--depth N]                   the dev instance's accessibility tree, as other apps (VoiceOver) see it
//   uidrive click <id> [--double] [--right]    real mouse click on the element with that accessibility identifier
//   uidrive drag <id> (--to <id> | --dx N --dy N) [--steps N]
//   uidrive key <name> [--mods cmd,shift,...]  real key press (tab, return, delete, up, z, ...)
//   uidrive type <text>                        real typing
//   uidrive shot <out.png> [--window <title substring>]   screenshot of ONE dev-instance window, cropped to it
//   uidrive pass                               short real-input pass over the editor, compared with the in-app channel
//   any command + --dry-run                    print what would happen; post nothing
//
// Real events move the owner's real pointer and go to whatever is frontmost, so before every action: the target must
// be in a window of the dev instance (pid from App/.scratch/uitest/session, executable under App/build-dev/), that
// window must be frontmost, the point must lie inside the window's frame; the pointer is put back afterwards; and the
// run aborts when the pointer is not where we left it or the HID system saw a key or mouse event that we did not post
// (the owner is using the computer).
import AppKit
import ApplicationServices
import Foundation

let env = ProcessInfo.processInfo.environment
let appDir = URL(fileURLWithPath: env["EQAPE_APP_DIR"] ?? FileManager.default.currentDirectoryPath, isDirectory: true)
let sessionDir = URL(fileURLWithPath: env["EQAPE_UITEST_SESSION"] ?? appDir.appendingPathComponent(".scratch/uitest/session").path, isDirectory: true)
var args = Array(CommandLine.arguments.dropFirst())
let dryRun = args.contains("--dry-run")
args.removeAll { $0 == "--dry-run" }

func die(_ s: String, _ code: Int32 = 2) -> Never { FileHandle.standardError.write(Data("uidrive: \(s)\n".utf8)); exit(code) }
func opt(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

// MARK: permissions

struct Perms { var ax: Bool; var screen: Bool; var post: Bool; var listen: Bool }
func perms() -> Perms {
    Perms(ax: AXIsProcessTrusted(), screen: CGPreflightScreenCaptureAccess(), post: CGPreflightPostEventAccess(), listen: CGPreflightListenEventAccess())
}
func requireAX() {
    let p = perms()
    if !p.ax {
        die("this terminal lacks Accessibility: System Settings › Privacy & Security › Accessibility › enable your terminal app (Terminal). Continue with the in-app channel (scripts/uitest) meanwhile.", 3)
    }
}

// MARK: dev instance

func pidPath(_ pid: Int32) -> String? {
    var buf = [CChar](repeating: 0, count: 4096)
    return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
}

let devPID: Int32 = {
    if let p = opt("--pid").flatMap(Int32.init) { return p }
    guard let d = try? Data(contentsOf: sessionDir.appendingPathComponent("session.json")),
          let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let p = j["pid"] as? Int else { return 0 }
    return Int32(p)
}()

func requireDev() {
    guard devPID > 0, kill(devPID, 0) == 0 else { die("no dev instance running (start one with scripts/uitest launch --no-engine)") }
    guard let p = pidPath(devPID), p.contains("/build-dev/") else { die("pid \(devPID) is not a dev bundle under App/build-dev/; refusing to drive it") }
}

// MARK: AX

let app = AXUIElementCreateApplication(devPID)

func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}
func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func frame(_ e: AXUIElement) -> CGRect? {
    guard let pv = attr(e, kAXPositionAttribute), let sv = attr(e, kAXSizeAttribute) else { return nil }
    var p = CGPoint.zero, s = CGSize.zero
    AXValueGetValue(pv as! AXValue, .cgPoint, &p)
    AXValueGetValue(sv as! AXValue, .cgSize, &s)
    return CGRect(origin: p, size: s)   // global display coordinates, origin top-left
}

func find(_ id: String, in root: AXUIElement, depth: Int = 0) -> AXUIElement? {
    if attr(root, "AXIdentifier") as? String == id { return root }
    guard depth < 60 else { return nil }
    for c in children(root) { if let f = find(id, in: c, depth: depth + 1) { return f } }
    return nil
}

func dump(_ e: AXUIElement, _ d: Int, _ maxDepth: Int) {
    let role = attr(e, kAXRoleAttribute) as? String ?? "?"
    let id = attr(e, "AXIdentifier") as? String ?? ""
    let label = (attr(e, kAXDescriptionAttribute) as? String) ?? (attr(e, kAXTitleAttribute) as? String) ?? ""
    print(String(repeating: "  ", count: d) + role + (id.isEmpty ? "" : " #\(id)") + (label.isEmpty ? "" : " \"\(label)\""))
    if d < maxDepth { for c in children(e) { dump(c, d + 1, maxDepth) } }
}

// MARK: safety

struct Abort: Error, CustomStringConvertible { var description: String }

let source = CGEventSource(stateID: .privateState)
var lastPosted = Date()
var expectedPointer: CGPoint?
let runStart = Date()

func pointer() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

/// The owner moved the pointer or used keyboard/mouse since our last action.
func ownerActivity() -> String? {
    if let e = expectedPointer {
        let p = pointer()
        if hypot(p.x - e.x, p.y - e.y) > 3 { return "pointer moved by someone else (expected \(e), now \(p))" }
    }
    let since = Date().timeIntervalSince(lastPosted)
    for (t, n) in [(CGEventType.keyDown, "key press"), (.leftMouseDown, "mouse click"), (.mouseMoved, "mouse movement")] {
        let s = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: t)
        if s < since - 0.05 && s < Date().timeIntervalSince(runStart) { return "\(n) on the HID system \(String(format: "%.2f", s)) s ago, not ours" }
    }
    return nil
}

func frontmostWindow() -> (pid: Int32, bounds: CGRect, title: String)? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
    for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
        let pid = Int32(w[kCGWindowOwnerPID as String] as? Int ?? 0)
        let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
        return (pid, CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0), w[kCGWindowName as String] as? String ?? "")
    }
    return nil
}

/// Locate the element, make sure its window is the dev instance's and frontmost, return the point (global, top-left).
func aim(_ id: String) throws -> (point: CGPoint, window: CGRect) {
    guard let el = find(id, in: app), let f = frame(el), f.width > 0 else { throw Abort(description: "no visible element #\(id) in the dev instance") }
    guard let win = attr(el, kAXWindowAttribute), let wf = frame(win as! AXUIElement) else { throw Abort(description: "#\(id) has no window") }
    if let fw = frontmostWindow(), fw.pid != devPID || !fw.bounds.intersects(wf) {
        if dryRun { print("  (dry run) would activate the dev instance") } else {
            NSRunningApplication(processIdentifier: devPID)?.activate()
            AXUIElementPerformAction(win as! AXUIElement, kAXRaiseAction as CFString)
            usleep(400_000)
        }
    }
    guard let fw = frontmostWindow() else { throw Abort(description: "cannot read the window list") }
    if !dryRun {
        guard fw.pid == devPID else { throw Abort(description: "frontmost window belongs to pid \(fw.pid), not the dev instance \(devPID)") }
        guard abs(fw.bounds.minX - wf.minX) < 2, abs(fw.bounds.minY - wf.minY) < 2 else {
            throw Abort(description: "the target window is not the frontmost window (frontmost: \"\(fw.title)\")")
        }
    }
    let p = CGPoint(x: f.midX, y: f.midY)
    guard wf.insetBy(dx: 2, dy: 2).contains(p) else { throw Abort(description: "#\(id) centre \(p) is outside its window \(wf)") }
    return (p, wf)
}

func post(_ e: CGEvent?) {
    guard let e else { return }
    e.post(tap: .cghidEventTap)
    lastPosted = Date()
}

func mouse(_ t: CGEventType, _ p: CGPoint, button: CGMouseButton = .left, clicks: Int = 1, flags: CGEventFlags = []) {
    let e = CGEvent(mouseEventSource: source, mouseType: t, mouseCursorPosition: p, mouseButton: button)
    e?.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
    e?.flags = flags
    post(e)
}

/// Runs `body` with the pointer restored afterwards and owner-activity checks before and after.
func guarded(_ what: String, _ body: () throws -> Void) throws {
    if let a = ownerActivity() { throw Abort(description: "aborting before \(what): \(a)") }
    let saved = pointer()
    print("  \(dryRun ? "(dry run) " : "")\(what)")
    if !dryRun {
        defer {
            CGWarpMouseCursorPosition(saved)
            CGAssociateMouseAndMouseCursorPosition(1)
            expectedPointer = saved
            lastPosted = Date()
        }
        try body()
        usleep(150_000)
    }
}

func click(_ id: String, clicks: Int = 1, right: Bool = false, flags: CGEventFlags = []) throws {
    let (p, _) = try aim(id)
    try guarded("click #\(id) at \(p)\(clicks == 2 ? " (double)" : "")\(right ? " (right)" : "")") {
        mouse(.mouseMoved, p)
        usleep(30_000)
        for n in 1...clicks {
            mouse(right ? .rightMouseDown : .leftMouseDown, p, button: right ? .right : .left, clicks: n, flags: flags)
            usleep(40_000)
            mouse(right ? .rightMouseUp : .leftMouseUp, p, button: right ? .right : .left, clicks: n, flags: flags)
            usleep(60_000)
        }
    }
}

func drag(_ id: String, to: String?, dx: Double, dy: Double, steps: Int, flags: CGEventFlags = [], hold: Bool = false) throws {
    let (p0, wf) = try aim(id)
    var p1 = CGPoint(x: p0.x + dx, y: p0.y - dy)   // dy > 0 = up
    if let to { p1 = try aim(to).point; p1.x += dx; p1.y -= dy }
    guard wf.insetBy(dx: 2, dy: 2).contains(p1) else { throw Abort(description: "drag end \(p1) is outside the window \(wf)") }
    try guarded("drag #\(id) \(p0) → \(p1)") {
        mouse(.mouseMoved, p0); usleep(50_000)
        mouse(.leftMouseDown, p0, flags: flags); usleep(hold ? 700_000 : 80_000)
        for i in 1...max(1, steps) {
            let t = CGFloat(i) / CGFloat(max(1, steps))
            mouse(.leftMouseDragged, CGPoint(x: p0.x + (p1.x - p0.x) * t, y: p0.y + (p1.y - p0.y) * t), flags: flags)
            usleep(hold ? 50_000 : 16_000)
        }
        usleep(hold ? 400_000 : 50_000)
        mouse(.leftMouseUp, p1, flags: flags)
    }
}

let keyCodes: [String: CGKeyCode] = ["return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53, "left": 123, "right": 124,
                                     "down": 125, "up": 126, "a": 0, "s": 1, "z": 6, "x": 7, "c": 8, "v": 9]

func flags(_ s: String?) -> CGEventFlags {
    var f: CGEventFlags = []
    for m in (s ?? "").split(separator: ",") {
        switch m { case "cmd", "command": f.insert(.maskCommand); case "shift": f.insert(.maskShift)
        case "option", "alt": f.insert(.maskAlternate); case "ctrl", "control": f.insert(.maskControl); default: break }
    }
    return f
}

func requireFrontDev() throws {
    guard dryRun || frontmostWindow()?.pid == devPID else { throw Abort(description: "the dev instance is not frontmost; refusing to send keys") }
}

func key(_ name: String, _ f: CGEventFlags = []) throws {
    guard let code = keyCodes[name] else { throw Abort(description: "unknown key \(name)") }
    try requireFrontDev()
    try guarded("key \(name)\(f.isEmpty ? "" : " with modifiers")") {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            e?.flags = f
            post(e); usleep(30_000)
        }
    }
}

func type(_ text: String) throws {
    try requireFrontDev()
    try guarded("type \"\(text)\"") {
        for ch in text.utf16 {
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                var c = ch
                e?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
                e?.flags = []   // explicit: a reused event source would otherwise carry ⌘ from a preceding ⌘A
                post(e); usleep(25_000)
            }
        }
    }
}

/// Screenshot of one dev-instance window only (screencapture -l: just that window, no shadow, no other content).
func shot(_ out: String, title: String?) throws {
    guard perms().screen else { throw Abort(description: "no Screen Recording permission: System Settings › Privacy & Security › Screen & System Audio Recording › enable your terminal") }
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { throw Abort(description: "no window list") }
    let mine = list.filter { Int32($0[kCGWindowOwnerPID as String] as? Int ?? 0) == devPID && ($0[kCGWindowLayer as String] as? Int) == 0 }
    guard let w = mine.first(where: { title == nil || (($0[kCGWindowName as String] as? String) ?? "").contains(title!) }),
          let wid = w[kCGWindowNumber as String] as? Int else { throw Abort(description: "no on-screen dev window\(title.map { " titled *\($0)*" } ?? "")") }
    if dryRun { print("  (dry run) screencapture -l\(wid) \(out)"); return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-l\(wid)", "-o", "-x", out]
    try p.run(); p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw Abort(description: "screencapture failed") }
    print("  shot \(out) (window \(wid) \"\(w[kCGWindowName as String] as? String ?? "")\" only)")
}

// MARK: channel (for comparisons)

func channel(_ cmd: [String: Any]) -> [String: Any] {
    let ctl = sessionDir.appendingPathComponent("ctl")
    let name = String(format: "%020llu-ud.json", UInt64(Date().timeIntervalSince1970 * 1e9))
    let tmp = ctl.appendingPathComponent("cmd/.\(name)")
    try? JSONSerialization.data(withJSONObject: cmd).write(to: tmp)
    try? FileManager.default.moveItem(at: tmp, to: ctl.appendingPathComponent("cmd/\(name)"))
    let res = ctl.appendingPathComponent("res/\(name)")
    for _ in 0..<1500 {
        if let d = try? Data(contentsOf: res), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            try? FileManager.default.removeItem(at: res); return o
        }
        usleep(20_000)
    }
    return [:]
}
func rows() -> [[String: Any]] { ((channel(["action": "state"])["state"] as? [String: Any])?["editor"] as? [String: Any])?["rows"] as? [[String: Any]] ?? [] }
func responder() -> String { ((channel(["action": "state"])["state"] as? [String: Any])?["app"] as? [String: Any])?["firstResponder"] as? String ?? "?" }
func text(_ id: String) -> String { rows().first { $0["id"] as? String == id }?["text"] as? String ?? "<gone>" }

/// Short real-input pass: the same gestures the in-app suite makes, with real events, compared with the channel's
/// results (the suite's posted-event drag of +40/-20 pt on Filter 1 gave the same line as the real drag must give).
func pass() throws {
    var ok = 0, bad = 0
    func check(_ n: String, _ c: Bool, _ d: String = "") { if c { ok += 1; print("  PASS \(n)") } else { bad += 1; print("  FAIL \(n) \(d)") } }
    let f1 = "row.suite.txt:3", orig = text(f1)
    guard orig.hasPrefix("Filter 1:") else { throw Abort(description: "the dev instance is not on the generated suite config (launch with scripts/uitest launch --no-engine)") }
    let shotDir = appDir.appendingPathComponent(".scratch/uidrive"); try? FileManager.default.createDirectory(at: shotDir, withIntermediateDirectories: true)

    // 1. in-app reference: posted-event drag, then undo
    _ = channel(["action": "drag", "target": "graph.handle.suite.txt:3", "dx": 40, "dy": -20, "steps": 8])
    let inApp = text(f1)
    _ = channel(["action": "key", "key": "z", "modifiers": ["command"]])
    check("in-app reference drag undone", text(f1) == orig, text(f1))

    // 2. the same drag with the real pointer
    try drag("graph.handle.suite.txt:3", to: nil, dx: 40, dy: -20, steps: 8)
    usleep(300_000)
    let real = text(f1)
    check("real drag changed the line", real != orig, real)
    check("real drag gives the same line as the in-app channel's drag", real == inApp, "real \(real) vs in-app \(inApp)")
    try shot(shotDir.appendingPathComponent("real-after-drag.png").path, title: "EQ Ape Editor")
    try key("z", .maskCommand); usleep(300_000)
    check("real ⌘Z undoes it", text(f1) == orig, text(f1))

    // 3. real click on the On checkbox, twice
    try click("\(f1).on"); usleep(300_000)
    check("real click turns Filter 1 OFF", text(f1).contains(": OFF "), text(f1))
    try click("\(f1).on"); usleep(300_000)
    check("second real click turns it ON", text(f1) == orig, text(f1))
    usleep(1_000_000)   // each toggle rebuilds the list rows; a person does not click the next field within 0.3 s

    // 4. real typing into the Fc field, Return commits
    try click("\(f1).fc.field", clicks: 1)
    usleep(400_000)   // let the field editor take over before typing (as a person would pause)
    print("    responder after the click: \(responder())")
    try key("a", .maskCommand)
    try type("250")
    usleep(200_000)
    print("    responder after typing: \(responder())")
    try key("return"); usleep(400_000)
    check("real typing + Return commits Fc 250", text(f1).contains("Fc 250 Hz"), text(f1))
    try key("escape")
    if text(f1) != orig { try key("z", .maskCommand); usleep(300_000) }
    check("undo restores", text(f1) == orig, text(f1))

    // 5. real list drag-reorder (an AppKit drag session: needs the real pointer)
    let before = rows().map { $0["text"] as? String ?? "" }
    try drag("\(f1).label", to: "row.suite.txt:5.label", dx: 0, dy: -8, steps: 20, hold: true)
    usleep(1_500_000)
    let after = rows().map { $0["text"] as? String ?? "" }
    let i1 = after.firstIndex { $0.hasPrefix("Filter 1:") } ?? -1, i3 = after.firstIndex { $0.hasPrefix("Filter 3:") } ?? -1
    check("real drag-to-reorder moves Filter 1 below Filter 3", after != before && i1 > i3, after.joined(separator: " | "))
    if after != before { try key("z", .maskCommand); usleep(300_000) }
    check("order restored", rows().map { $0["text"] as? String ?? "" } == before)
    print("uidrive pass: \(ok) passed, \(bad) failed")
    if bad > 0 { exit(1) }
}

// MARK: main

guard let cmd = args.first else { die("usage: uidrive perms | tree | click <id> | drag <id> | key <name> | type <text> | shot <out.png> | pass  [--dry-run]") }
do {
    switch cmd {
    case "perms":
        let p = perms()
        print("Accessibility (AXIsProcessTrusted):            \(p.ax)\(p.ax ? "" : "   -> enable the terminal in System Settings › Privacy & Security › Accessibility")")
        print("Screen Recording (CGPreflightScreenCapture):   \(p.screen)\(p.screen ? "" : "   -> enable it under Screen & System Audio Recording")")
        print("Post events (CGPreflightPostEventAccess):      \(p.post)")
        print("Listen events / Input Monitoring:              \(p.listen) (not needed: activity is detected from HID idle times and the pointer position)")
        print(p.ax ? "real-input mode available" : "real-input mode NOT available; use the in-app channel (scripts/uitest)")
    case "tree":
        requireAX(); requireDev()
        dump(app, 0, Int(opt("--depth") ?? "") ?? 30)
    case "click":
        requireAX(); requireDev()
        guard args.count > 1 else { die("click <id>") }
        try click(args[1], clicks: args.contains("--double") ? 2 : 1, right: args.contains("--right"), flags: flags(opt("--mods")))
    case "drag":
        requireAX(); requireDev()
        guard args.count > 1 else { die("drag <id> (--to <id> | --dx N --dy N)") }
        try drag(args[1], to: opt("--to"), dx: Double(opt("--dx") ?? "0") ?? 0, dy: Double(opt("--dy") ?? "0") ?? 0,
                 steps: Int(opt("--steps") ?? "10") ?? 10, flags: flags(opt("--mods")))
    case "key":
        requireAX(); requireDev()
        guard args.count > 1 else { die("key <name>") }
        try key(args[1], flags(opt("--mods")))
    case "type":
        requireAX(); requireDev()
        guard args.count > 1 else { die("type <text>") }
        try type(args[1])
    case "shot":
        requireDev()
        guard args.count > 1 else { die("shot <out.png>") }
        try shot(args[1], title: opt("--window"))
    case "pass":
        requireAX(); requireDev()
        try pass()
    default:
        die("unknown command \(cmd)")
    }
} catch {
    die("\(error)", 1)
}
