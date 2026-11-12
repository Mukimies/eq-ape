import Foundation

/// `uitest suite`: scripted end-to-end run against a fresh --no-engine dev instance on the generated scratch config.
/// Every step uses real UI actions through the channel (synthesised events at the element's on-screen position),
/// except where noted ("model path"). Screenshots go to App/.scratch/uitest-suite/<time>/ (or --out).
enum Suite {
    static var passes = 0, failures: [String] = [], notes: [String] = []
    static var focusLost = 0
    static var lastActionActive = true
    static var step = ""
    static var shotDir = URL(fileURLWithPath: "/tmp")
    static var shotIndex = 0

    static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { passes += 1; print("  PASS \(name)") } else {
            var d = detail()
            if (send(["action": "ping"], timeout: 5)["appActive"] as? Bool) == false || !lastActionActive {
                focusLost += 1
                d += (d.isEmpty ? "" : " ") + "[EQ Ape was not the active app during this step: another app had keyboard focus]"
            }
            failures.append("[\(step)] \(name)\(d.isEmpty ? "" : ": \(d)")")
            print("  FAIL \(name)\(d.isEmpty ? "" : ": \(d)")")
        }
    }

    static func note(_ s: String) { notes.append("[\(step)] \(s)"); print("  NOTE \(s)") }

    @discardableResult
    static func act(_ cmd: [String: Any], expectOK: Bool = true) -> [String: Any] {
        let r = send(cmd, timeout: 30)
        if let a = r["appActive"] as? Bool { lastActionActive = a }
        if expectOK && (r["ok"] as? Bool) != true {
            failures.append("[\(step)] action \(cmd["action"] ?? "?") \(cmd["target"] ?? "") failed: \(r["error"] ?? "?")")
            print("  FAIL action \(json(cmd).replacingOccurrences(of: "\n", with: " ")): \(r["error"] ?? "?")")
        }
        return r
    }

    @discardableResult
    static func click(_ t: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        act(["action": "click", "target": t].merging(extra) { $1 })
    }

    static func key(_ k: String, _ mods: [String] = [], repeatCount: Int = 1) {
        act(["action": "key", "key": k, "modifiers": mods, "repeat": repeatCount])
    }

    static func state() -> [String: Any] { send(["action": "state"])["state"] as? [String: Any] ?? [:] }
    static func val(_ path: String) -> Any? { lookup(state(), path) }

    static func rows() -> [[String: Any]] { (val("editor.rows") as? [[String: Any]]) ?? [] }
    static func row(_ match: String) -> [String: Any]? { rows().first { ($0["text"] as? String)?.contains(match) == true } }
    static func rid(_ match: String) -> String {
        guard let r = row(match), let id = r["id"] as? String else { return "row.missing(\(match))" }
        return id
    }
    static func text(_ id: String) -> String { (rows().first { $0["id"] as? String == id }?["text"] as? String) ?? "<gone>" }
    static func undoCount() -> Int { val("editor.undoCount") as? Int ?? -1 }

    @discardableResult
    static func waitFor(_ path: String, _ cond: [String: Any], timeout: Double = 5) -> Bool {
        var c = cond; c["action"] = "wait"; c["path"] = path; c["timeout"] = timeout
        return (send(c, timeout: timeout + 10)["ok"] as? Bool) == true
    }

    static func shot(_ name: String, window: String = "editor") {
        shotIndex += 1
        let file = shotDir.appendingPathComponent(String(format: "%02d-%@.png", shotIndex, name)).path
        let r = act(["action": "shot", "name": name, "window": window, "path": file])
        if (r["ok"] as? Bool) == true { print("  shot \(file)") }
    }

    static func undoUntil(_ id: String, equals original: String, max: Int = 20) {
        var n = 0
        while text(id) != original && n < max && (val("editor.canUndo") as? Bool) == true { key("z", ["command"]); n += 1 }
    }

    /// EQAPE_SUITE_STOP_BEFORE=<n>: stop before step n and leave the instance running (debugging).
    static func begin(_ s: String) {
        if let stop = env["EQAPE_SUITE_STOP_BEFORE"].flatMap(Int.init), let n = Int(s.prefix(2)), n >= stop {
            print("stopping before step \(s) (EQAPE_SUITE_STOP_BEFORE); the instance keeps running: scripts/uitest quit")
            exit(failures.isEmpty ? 0 : 1)
        }
        step = s; print("== \(s)")
    }

    static func run(outDir: String?) -> Int32 {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        shotDir = URL(fileURLWithPath: outDir ?? appDir.appendingPathComponent(".scratch/uitest-suite/\(stamp)").path, isDirectory: true)
        try? FileManager.default.createDirectory(at: shotDir, withIntermediateDirectories: true)
        if liveSession() != nil { quit() }
        let s = launch(LaunchOptions(engine: false))
        let cfg = URL(fileURLWithPath: s.config!)
        let extra = cfg.deletingLastPathComponent().appendingPathComponent("suite-extra.txt")
        let original = (try? Data(contentsOf: cfg)) ?? Data()
        let originalExtra = (try? Data(contentsOf: extra)) ?? Data()
        let t0 = Date()
        defer { }

        begin("01 launch")
        check("editor window open", waitFor("editor.rows[0].id", ["exists": true], timeout: 10))
        check("engine off (--no-engine)", val("app.engineDisabled") as? Bool == true)
        check("permission gate reported", val("app.requireGranted") as? Bool == true)
        _ = act(["action": "activate"])
        shot("editor-initial")
        let missing = (act(["action": "audit"])["missing"] as? [[String: Any]]) ?? []
        check("every interactive control in the editor has an accessibility identifier", missing.isEmpty, json(missing))
        let elems = (act(["action": "elements"])["elements"] as? [[String: Any]]) ?? []
        check("graph handles exposed", elems.contains { ($0["id"] as? String)?.hasPrefix("graph.handle.") == true })
        check("row graph nodes exposed", elems.contains { ($0["id"] as? String)?.contains(".node.") == true })

        begin("02 graph handle: drag, option-drag, scroll, undo/redo")
        let f1 = rid("Filter 1:"), f1orig = text(f1)
        let handle = "graph.handle.suite.txt:\(f1.split(separator: ":").last ?? "3")"
        act(["action": "drag", "target": handle, "dx": 40, "dy": -20, "steps": 8])
        let afterDrag = text(f1)
        check("drag changed Fc and gain", afterDrag != f1orig && !afterDrag.contains("Fc 120 Hz") && !afterDrag.contains("Gain -6 dB"), afterDrag)
        check("drag kept Q", afterDrag.hasSuffix("Q 4"), afterDrag)
        act(["action": "drag", "target": handle, "dy": 30, "steps": 6, "modifiers": ["option"]])
        let afterQ = text(f1)
        check("option-drag changed only Q", afterQ != afterDrag && afterQ.components(separatedBy: " Q ").first == afterDrag.components(separatedBy: " Q ").first, afterQ)
        act(["action": "scroll", "target": handle, "dy": -4])
        let afterScroll = text(f1)
        check("scroll wheel over the handle changed Q", afterScroll != afterQ, afterScroll)
        check("peak label present", (val("editor.plot.peakLabel") as? String)?.hasPrefix("peak") == true)
        RunLoopWait(0.8)   // the scroll gesture ends after 0.6 s
        key("z", ["command"]); key("z", ["command"]); key("z", ["command"])
        check("⌘Z ×3 restores the line", text(f1) == f1orig, text(f1))
        key("z", ["command", "shift"])
        check("⇧⌘Z redoes the drag", text(f1) == afterDrag, text(f1))
        click("editor.undo")
        check("toolbar Undo button undoes", text(f1) == f1orig, text(f1))
        check("redo available after undo", val("editor.canRedo") as? Bool == true)

        begin("03 double-click on the graph adds a filter")
        let nFilters = rows().filter { $0["kind"] as? String == "filter" }.count
        if let g = elems.first(where: { $0["id"] as? String == "editor.graph" }), let fr = g["frame"] as? [Double], fr.count == 4 {
            act(["action": "doubleClick", "target": "editor.graph", "offset": [fr[2] * 0.3, fr[3] * 0.32]])
            check("a filter was added", rows().filter { $0["kind"] as? String == "filter" }.count == nFilters + 1)
            check("the new filter is selected", (val("editor.selection.text") as? String)?.contains("PK") == true, "\(val("editor.selection.text") ?? "-")")
            key("z", ["command"])
            check("undo removes it", rows().filter { $0["kind"] as? String == "filter" }.count == nFilters)
        } else { check("graph element found", false) }

        begin("04 GraphicEQ nodes: click, arrow-key nudges, Tab, Delete (main graph and row graph)")
        let geq = rid("GraphicEQ:"), geqOrig = text(geq)
        click("\(geq).label")
        if val("editor.selection.id") as? String != geq {
            note("clicking the row's title did not select the row; selected through the channel instead")
            act(["action": "select", "row": geq])
        }
        check("GraphicEQ row selected", val("editor.selection.id") as? String == geq)
        click("graph.node.4")
        check("click on node 4 selects it", val("editor.geqNode") as? Int == 3, "\(val("editor.geqNode") ?? "-")")
        func node(_ i: Int) -> [Double] { (rows().first { $0["id"] as? String == geq }?["nodes"] as? [[Double]]).map { $0.indices.contains(i) ? $0[i] : [] } ?? [] }
        let n4 = node(3)
        key("up")
        check("↑ = +0.5 dB", abs((node(3).last ?? 0) - ((n4.last ?? 0) + 0.5)) < 1e-6, "\(node(3))")
        key("right")
        check("→ raises the frequency (1/24 octave)", (node(3).first ?? 0) > (n4.first ?? 0), "\(node(3))")
        key("up", ["shift"])
        check("⇧↑ = +1 dB", abs((node(3).last ?? 0) - ((n4.last ?? 0) + 1.5)) < 1e-6, "\(node(3))")
        key("tab")
        check("Tab selects the next node", val("editor.geqNode") as? Int == 4, "\(val("editor.geqNode") ?? "-")")
        key("tab", ["shift"])
        check("⇧Tab selects the previous node", val("editor.geqNode") as? Int == 3, "\(val("editor.geqNode") ?? "-")")
        let count0 = (rows().first { $0["id"] as? String == geq }?["nodes"] as? [Any])?.count ?? 0
        key("delete")
        let count1 = (rows().first { $0["id"] as? String == geq }?["nodes"] as? [Any])?.count ?? 0
        check("Delete removes the selected node", count1 == count0 - 1, "\(count0) -> \(count1)")
        shot("geq-nudged")
        click("\(geq).node.2")
        let n2 = node(1)
        key("down")
        check("row graph: click selects, ↓ = -0.5 dB", abs((node(1).last ?? 0) - ((n2.last ?? 0) - 0.5)) < 1e-6, "\(n2) -> \(node(1))")
        undoUntil(geq, equals: geqOrig)
        check("undo restores the GraphicEQ line", text(geq) == geqOrig, text(geq))

        begin("05 Tab order through the number fields")
        let fc1 = click("\(f1).fc.field")
        if val("app.focus") as? String != "\(f1).fc.field" {
            note("the first click on the Fc field (hit \(fc1["hitView"] ?? "-") at \(fc1["point"] ?? "-")) gave focus to \(val("app.focus") ?? "-"), responder \(val("app.firstResponder") ?? "-"); clicked again")
            click("\(f1).fc.field")
        }
        var seqIDs: [String] = [(val("app.focus") as? String) ?? "\(val("app.firstResponder") ?? "?")"]
        for _ in 0..<7 { key("tab"); seqIDs.append((val("app.focus") as? String) ?? "\(val("app.firstResponder") ?? "?")") }
        note("focus sequence: \(seqIDs.joined(separator: " → "))")
        check("Fc field focused by clicking it", seqIDs.first == "\(f1).fc.field", seqIDs.first ?? "")
        if let a = seqIDs.firstIndex(of: "\(f1).fc.field"), let b = seqIDs.firstIndex(of: "\(f1).gain.field"), let c = seqIDs.firstIndex(of: "\(f1).q.field") {
            check("Tab goes Fc → Gain → Q within the row", a < b && b < c)
        } else { check("Tab reaches Fc, Gain and Q fields", false, seqIDs.joined(separator: ", ")) }
        let f2 = rid("Filter 2:")
        if let q = seqIDs.firstIndex(of: "\(f1).q.field"), q + 1 < seqIDs.count {
            note("after the last field of a row Tab goes to \(seqIDs[q + 1])\(seqIDs[q + 1].hasPrefix(f2) ? " (the next row)" : ", not into the next row (known issue, docs/EDITOR-NOTES.md)")")
        }
        // Type picker (a pop-up menu)
        click("\(f2).type")
        let tm = act(["action": "menu", "open": "tracked", "item": "HP  High-pass"])
        check("Type pop-up: choosing HP changes the line", text(f2).contains(" HP "), "\(text(f2)) \(tm["error"] ?? "")")
        key("z", ["command"])
        check("undo restores the type", text(f2).contains(" LSC "), text(f2))
        key("escape")

        begin("06 number fields: type and commit (Return, focus change, comma decimal, invalid text)")
        let t1 = act(["action": "type", "target": "\(f1).fc.field", "text": "250", "selectAll": true, "commit": true])
        if (t1["clicksToFocus"] as? Int ?? 1) > 1 { note("the Fc field needed \(t1["clicksToFocus"] ?? 2) clicks to take focus") }
        check("Return commits Fc 250", text(f1).contains("Fc 250 Hz"), text(f1))
        act(["action": "type", "target": "\(f1).gain.field", "text": "-4,5", "selectAll": true])
        key("tab")
        check("Tab (focus change) commits gain, decimal comma accepted", text(f1).contains("Gain -4.5 dB"), text(f1))
        let beforeBad = text(f1)
        act(["action": "type", "target": "\(f1).q.field", "text": "abc", "selectAll": true, "commit": true])
        check("invalid text changes nothing", text(f1) == beforeBad, text(f1))
        shot("fields-committed")
        undoUntil(f1, equals: f1orig)
        check("undo restores Filter 1", text(f1) == f1orig, text(f1))

        begin("07 Delete key and trash button on a list row")
        let f3 = rid("Filter 3:")
        click("\(f3).label")
        if val("editor.selection.id") as? String != f3 { note("row title click did not select; channel select used"); act(["action": "select", "row": f3]) }
        // the list must have focus for its Delete command
        key("delete")
        check("Delete removes the selected row", row("Filter 3:") == nil)
        key("z", ["command"])
        check("undo brings it back", row("Filter 3:") != nil)
        click("\(rid("Filter 3:")).delete")
        check("trash button removes the row", row("Filter 3:") == nil)
        key("z", ["command"])
        check("undo brings it back again", row("Filter 3:") != nil)

        begin("08 power / on toggles and context menu")
        click("\(f1).on")
        check("On checkbox turns the filter OFF", text(f1).contains(": OFF "), text(f1))
        click("\(f1).on")
        check("and ON again", text(f1).contains(": ON "), text(f1))
        let geqID = rid("GraphicEQ:")
        click("\(geqID).power")
        check("GraphicEQ power toggle comments the line out", text(geqID).hasPrefix("#"), text(geqID))
        shot("geq-power-off")
        click("\(geqID).power")
        check("and enables it again", text(geqID) == geqOrig, text(geqID))
        act(["action": "rightClick", "target": "\(f1).label"])
        let menu1 = act(["action": "menu", "open": "tracked", "item": "Turn On/Off"])
        check("context menu Turn On/Off", text(f1).contains(": OFF "), "\(text(f1)) \(menu1["error"] ?? "")")
        act(["action": "rightClick", "target": "\(f1).label"])
        act(["action": "menu", "open": "tracked", "item": "Comment Out"])
        check("context menu Comment Out", text(f1).hasPrefix("#"), text(f1))
        act(["action": "rightClick", "target": "\(f1).text"])
        act(["action": "menu", "open": "tracked", "item": "Enable (Remove #)"])
        check("context menu Enable (Remove #)", !text(f1).hasPrefix("#"), text(f1))
        undoUntil(f1, equals: f1orig)
        check("undo restores", text(f1) == f1orig, text(f1))

        begin("09 enable / comment out a commented filter")
        let c1 = rid("# Filter: ON PK Fc 400"), c1orig = text(c1)
        click("\(c1).enable")
        check("Enable removes the #", text(c1) == "Filter: ON PK Fc 400 Hz Gain -2 dB Q 2", text(c1))
        check("it became a filter with a handle", rows().first { $0["id"] as? String == c1 }?["kind"] as? String == "filter")
        act(["action": "rightClick", "target": "\(c1).label"])
        act(["action": "menu", "open": "tracked", "item": "Comment Out"])
        check("Comment Out puts the # back", text(c1).hasPrefix("#"), text(c1))
        key("z", ["command"]); key("z", ["command"])
        check("undo ×2 restores", text(c1) == c1orig, text(c1))
        key("z", ["command", "shift"])
        check("redo re-enables", !text(c1).hasPrefix("#"), text(c1))
        key("z", ["command"])

        begin("10 every Add menu item")
        act(["action": "select", "row": f1])
        let rows0 = rows().count
        click("editor.add", ["at": "left"])
        check("Add (primary) adds a peaking filter after the selection", rows().count == rows0 + 1 && (val("editor.selection.text") as? String)?.contains("PK Fc 1000 Hz") == true,
              "\(val("editor.selection.text") ?? "-")")
        key("z", ["command"])
        let items: [(String, String, Int?)] = [("Add Filter (peaking)", "filter", nil), ("Add Graphic EQ (variable)", "variable", 5),
                                              ("Add Graphic EQ (15 bands)", "fixed15", 15), ("Add Graphic EQ (31 bands)", "fixed31", 31)]
        for (title, kind, nodes) in items {
            act(["action": "select", "row": f1])
            click("editor.add", ["at": "right"])
            let m = act(["action": "menu", "open": "tracked", "item": title])
            let sel = rows().first { $0["id"] as? String == (val("editor.selection.id") as? String) }
            if let nodes {
                check("\(title)", sel?["layout"] as? String == kind && (sel?["nodes"] as? [Any])?.count == nodes,
                      "\(sel?["layout"] ?? "-") \((sel?["nodes"] as? [Any])?.count ?? 0) \(m["error"] ?? "")")
                if title.contains("15") { shot("add-geq-15") }
            } else {
                check("\(title)", sel?["kind"] as? String == "filter" && rows().count == rows0 + 1, "\(m["error"] ?? "")")
            }
            key("z", ["command"])
        }
        check("undo removed every added line", rows().count == rows0, "\(rows().count) vs \(rows0)")

        begin("11 15-band / 31-band / Variable conversion alert")
        act(["action": "select", "row": geqID])
        check("line starts Variable", (rows().first { $0["id"] as? String == geqID }?["layout"] as? String) == "variable")
        click("\(geqID).mode>31-band")
        let al = act(["action": "alert", "shot": shotDir.appendingPathComponent(String(format: "%02d-conversion-alert.png", shotIndex + 1)).path])
        shotIndex += 1
        check("conversion asks first", ((al["texts"] as? [String]) ?? []).contains { $0.contains("Convert to 31 bands") }, json(al))
        act(["action": "alert", "button": "Cancel"])
        check("Cancel keeps the line", text(geqID) == geqOrig)
        check("Cancel keeps Variable", (rows().first { $0["id"] as? String == geqID }?["layout"] as? String) == "variable")
        click("\(geqID).mode>31-band")
        act(["action": "alert", "button": "Convert"])
        let conv = rows().first { $0["id"] as? String == geqID }
        check("Convert resamples to 31 bands", conv?["layout"] as? String == "fixed31" && (conv?["nodes"] as? [Any])?.count == 31,
              "\(conv?["layout"] ?? "-")")
        shot("converted-31")
        click("\(geqID).mode>Variable")
        check("31 → Variable needs no alert and leaves the file alone", (rows().first { $0["id"] as? String == geqID }?["layout"] as? String) == "variable"
              && (rows().first { $0["id"] as? String == geqID }?["nodes"] as? [Any])?.count == 31)
        click("\(geqID).mode>15-band")
        act(["action": "alert", "button": "Convert"])
        check("Variable(31 nodes) → 15 bands", (rows().first { $0["id"] as? String == geqID }?["nodes"] as? [Any])?.count == 15)
        undoUntil(geqID, equals: geqOrig)
        check("undo restores the original nodes", text(geqID) == geqOrig, text(geqID))

        begin("12 reorder")
        let order0 = rows().map { $0["text"] as? String ?? "" }
        act(["action": "drag", "target": "\(f1).label", "to": "\(rid("Filter 3:")).label", "steps": 12])
        let order1 = rows().map { $0["text"] as? String ?? "" }
        note(order1 == order0 ? "a drag of synthesised in-process events does not start a list drag session (AppKit drag sessions follow the real pointer); covered by uidrive's real-input pass" : "posted-event drag reordered the list")
        if order1 != order0 { key("z", ["command"]) }
        act(["action": "move", "row": f1, "to": 5])   // model path (List.onMove)
        let order2 = rows().map { $0["text"] as? String ?? "" }
        check("onMove path moves Filter 1 below Filter 3 (model path)", (order2.firstIndex { $0.hasPrefix("Filter 1:") } ?? 0) > (order2.firstIndex { $0.hasPrefix("Filter 3:") } ?? 99), order2.joined(separator: " | "))
        key("z", ["command"])
        check("undo restores the order", rows().map { $0["text"] as? String ?? "" } == order0)

        begin("13 band-slider sheet")
        click("\(geqID).sliders")
        check("sheet attached", waitFor("editor.sheet", ["exists": true], timeout: 3))
        shot("geq-sheet")
        let sheetMissing = (act(["action": "audit"])["missing"] as? [[String: Any]]) ?? []
        check("sheet controls have identifiers", sheetMissing.isEmpty, json(sheetMissing))
        click("geq.band.3")
        key("up")
        check("band slider click + ↑ changed band 3", text(geqID) != geqOrig, text(geqID))
        click("geq.done")
        check("Done closes the sheet", waitFor("editor.sheet", ["exists": false], timeout: 3))
        undoUntil(geqID, equals: geqOrig)
        check("undo restores", text(geqID) == geqOrig, text(geqID))

        begin("14 warnings popover and jump")
        click("editor.status.warnings")
        check("popover open", waitFor("windows", ["contains": "popover"], timeout: 2) || ((val("windows") as? [[String: Any]])?.contains { $0["name"] as? String == "popover" } == true))
        shot("warnings-popover")
        click("warnings.item.1")
        check("clicking a warning selects its line", (val("editor.selection.text") as? String) == "This line is not valid", "\(val("editor.selection.text") ?? "-")")
        check("and closes the popover", !((val("windows") as? [[String: Any]])?.contains { $0["name"] as? String == "popover" } ?? true))

        begin("15 revert to version at open")
        act(["action": "type", "target": "\(f1).gain.field", "text": "-1", "selectAll": true, "commit": true])
        check("edit made", text(f1).contains("Gain -1 dB"), text(f1))
        click("editor.revert")
        check("Revert restores the line", text(f1) == f1orig, text(f1))
        check("nothing modified since open", val("editor.modified") as? Bool == false)
        key("z", ["command"])
        check("Revert is undoable", text(f1).contains("Gain -1 dB"), text(f1))
        undoUntil(f1, equals: f1orig)

        begin("16 menu bar extra")
        let mm = act(["action": "menu"])
        let titles = ((mm["items"] as? [[String: Any]]) ?? []).map { $0["title"] as? String ?? "" }
        check("menu lists its items", titles.contains("Open Editor…") && titles.contains("Settings…") && titles.contains("Quit EQ Ape"), titles.joined(separator: ", "))
        check("EQ Ape On is disabled with --no-engine", ((mm["items"] as? [[String: Any]]) ?? []).first { $0["title"] as? String == "EQ Ape On" }?["enabled"] as? Bool == false)
        act(["action": "menu", "item": "Settings…"])
        check("Settings… opens the Settings window", waitFor("windows", ["exists": true]) && ((val("windows") as? [[String: Any]])?.contains { $0["name"] as? String == "settings" } == true))

        begin("17 Settings window")
        shot("settings", window: "settings")
        let setMissing = (act(["action": "audit"])["missing"] as? [[String: Any]])?.filter { $0["window"] as? String == "settings" } ?? []
        check("Settings controls have identifiers", setMissing.isEmpty, json(setMissing))
        let profiles = (val("settings.profiles") as? [String: Any]) ?? [:]
        if let cur = profiles.keys.first(where: { $0 != "uid-uitest-unplugged" }) {
            let p = "settings.profile.\(cur)"
            click("\(p).enabled")
            check("Enabled switch turns the profile off", waitFor("settings.profiles.\(cur).enabled", ["equals": false]))
            check("written to the scratch settings.json", (try? String(contentsOfFile: s.settings, encoding: .utf8))?.contains("\"enabled\" : false") == true)
            click("\(p).enabled")
            check("and on again", waitFor("settings.profiles.\(cur).enabled", ["equals": true]))
            click("\(p).antiClip")
            check("anti-clip checkbox off", waitFor("settings.profiles.\(cur).headroomEnabled", ["equals": false]))
            click("\(p).antiClip")
            check("anti-clip checkbox on", waitFor("settings.profiles.\(cur).headroomEnabled", ["equals": true]))
            let h0 = val("settings.profiles.\(cur).headroomDB") as? Double ?? -1
            click("\(p).headroom", ["at": "right", "offset": [0, 4]])
            let h1 = val("settings.profiles.\(cur).headroomDB") as? Double ?? -1
            check("headroom stepper up = +0.5 dB", abs(h1 - (h0 + 0.5)) < 1e-9, "\(h0) -> \(h1)")
            click("\(p).headroom", ["at": "right", "offset": [0, -4]])
            check("headroom stepper down", abs((val("settings.profiles.\(cur).headroomDB") as? Double ?? -1) - h0) < 1e-9)
            click("\(p).choose")
            let panel = act(["action": "alert", "timeout": 4])
            check("Choose… opens the file panel", (panel["buttons"] as? [String])?.contains("Cancel") == true, json(panel))
            act(["action": "alert", "button": "Cancel"])
            check("Cancel leaves the profile", (val("settings.profiles.\(cur).configPath") as? String) == s.config)
            click("\(p).edit")
            check("Edit… brings up the editor on that config", (val("editor.path") as? String) == s.config && (val("editor.key") as? Bool) == true)
            act(["action": "open", "window": "settings"])
        } else { note("no profile for the current output device (no default output?)") }
        let opened0 = (val("app.opened") as? [String])?.count ?? 0
        click("settings.openSettingsFolder"); click("settings.openBackups"); click("settings.privacy")
        let opened = (val("app.opened") as? [String]) ?? []
        check("folder and privacy buttons act (recorded, not opened, in a UI-test run)", opened.count == opened0 + 3, opened.joined(separator: ", "))
        click("settings.profile.uid-uitest-unplugged.remove")
        check("Remove forgets the unplugged device's profile", waitFor("settings.profiles.uid-uitest-unplugged", ["exists": false]))
        note("Launch at Login was not toggled (never is); in a UI-test run the app refuses it anyway")
        act(["action": "appearance", "mode": "dark"])
        shot("settings-dark", window: "settings")
        act(["action": "close", "window": "settings"])

        begin("18 first-run window")
        // regression: opening this window could crash the app (constraint-pass exception), so open it repeatedly in
        // both appearances
        for i in 0..<6 {
            act(["action": "appearance", "mode": i % 2 == 0 ? "light" : "dark"])
            act(["action": "open", "window": "firstRun"])
            act(["action": "close", "window": "firstRun"])
        }
        check("first-run window opened and closed 6 times without a crash", (send(["action": "ping"], timeout: 5)["ok"] as? Bool) == true)
        act(["action": "appearance", "mode": "dark"])
        act(["action": "open", "window": "firstRun"])
        shot("first-run", window: "firstRun")
        act(["action": "appearance", "mode": "system"])
        click("firstRun.notNow")
        check("Not Now closes it", !((val("windows") as? [[String: Any]])?.contains { $0["name"] as? String == "firstRun" } ?? true))

        begin("19 window resize")
        act(["action": "open", "window": "editor"])
        let small = act(["action": "resize", "window": "editor", "width": 960, "height": 600])
        shot("editor-min-size")
        let inside = (act(["action": "elements", "prefix": "editor.status.warnings"])["elements"] as? [[String: Any]])?.first
        if let fr = inside?["frame"] as? [Double], let wf = small["frame"] as? [Double] {
            check("status strip still inside the window at 960×600", fr[0] >= wf[0] && fr[0] + fr[2] <= wf[0] + wf[2] + 0.5 && fr[1] >= wf[1] - 0.5, "\(fr) in \(wf)")
        } else { check("status strip visible at the minimum size", false) }
        act(["action": "resize", "window": "editor", "width": 800, "height": 500])
        let clamped = (val("editor.frame") as? [Double]) ?? []
        check("window does not shrink below its minimum", clamped.count == 4 && clamped[2] >= 960 && clamped[3] >= 600, "\(clamped)")
        act(["action": "resize", "window": "editor", "width": 1500, "height": 950])
        shot("editor-large")
        act(["action": "appearance", "mode": "dark"])
        shot("editor-dark")
        act(["action": "appearance", "mode": "system"])
        act(["action": "resize", "window": "editor", "width": 1180, "height": 780])

        begin("20 undo everything, files back to the original bytes")
        var n = 0
        while (val("editor.canUndo") as? Bool) == true && n < 300 { key("z", ["command"]); n += 1 }
        waitFor("editor.pending", ["equals": 0], timeout: 3)
        RunLoopWait(0.5)
        check("config file bytes equal the original", ((try? Data(contentsOf: cfg)) ?? Data()) == original)
        check("included file bytes equal the original", ((try? Data(contentsOf: extra)) ?? Data()) == originalExtra)
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: sessionDir.appendingPathComponent("backups").path)) ?? []
        check("a backup session folder was written to the scratch backup dir", !backups.isEmpty)
        let log = (try? String(contentsOfFile: sessionDir.appendingPathComponent("app.log").path, encoding: .utf8)) ?? ""
        check("app printed the --require-granted preflight line", log.contains("--require-granted"))
        quit()
        check("dev instance exited", !alive(s.pid))

        print("\nsuite: \(passes) passed, \(failures.count) failed, \(String(format: "%.0f", Date().timeIntervalSince(t0))) s; screenshots in \(shotDir.path)")
        if focusLost > 0 { print("\(focusLost) failure(s) happened while EQ Ape was not the active app (someone else was using the Mac?); rerun when the computer is idle") }
        for n in notes { print("note: \(n)") }
        for f in failures { print("FAILED: \(f)") }
        return failures.isEmpty ? 0 : 1
    }
}

func RunLoopWait(_ s: Double) { usleep(UInt32(s * 1e6)) }
