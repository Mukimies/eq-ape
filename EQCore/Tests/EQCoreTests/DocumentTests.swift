import XCTest
@testable import EQCore

final class DocumentTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("eqcore-doc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    @discardableResult
    func write(_ name: String, _ data: Data) throws -> URL {
        let u = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: u)
        return u
    }
    @discardableResult
    func writeText(_ name: String, _ text: String) throws -> URL { try write(name, Data(text.utf8)) }

    static let rewLF = H.fixtureText + "\n"
    static var rewCRLF: String { rewLF.replacingOccurrences(of: "\n", with: "\r\n") }
    static func utf16(_ s: String, bigEndian: Bool) -> Data {
        (bigEndian ? Data([0xFE, 0xFF]) : Data([0xFF, 0xFE])) + s.data(using: bigEndian ? .utf16BigEndian : .utf16LittleEndian)!
    }

    /// Byte fixtures covering line endings, encodings, spacing and trailing-newline variants.
    static var fixtures: [(String, Data)] {
        [
            ("rew-lf", Data(rewLF.utf8)),
            ("rew-crlf", Data(rewCRLF.utf8)),
            ("rew-no-final-newline", Data(H.fixtureText.utf8)),
            ("utf8-bom-crlf", Data([0xEF, 0xBB, 0xBF]) + Data(rewCRLF.utf8)),
            ("utf16le-crlf", utf16(rewCRLF, bigEndian: false)),
            ("utf16be-lf", utf16(rewLF, bigEndian: true)),
            ("mixed-endings", Data("Preamp: -1 dB\r\nFilter: ON PK Fc 100 Hz Gain 1 dB Q 1\n\rChannel: L\r\r\n\n".utf8)),
            ("spacing-tabs", Data("  Preamp:\t-1,5 dB   \n\tFilter  2: ON  PK       Fc   118.0 Hz  Gain -14.80 dB  Q 10.339  \n\n\n".utf8)),
            ("unicode", Data("# Säätö – ääkköset ✓\nPreamp: -1 dB\n".utf8)),
            ("empty", Data()),
            ("only-newline", Data("\n".utf8)),
        ]
    }

    // MARK: byte-exact round trip

    func testUnmodifiedRoundTripIsByteExact() throws {
        for (name, data) in DocumentTests.fixtures {
            let doc = ConfigDocument(data: data)
            XCTAssertFalse(doc.readOnly, name)
            XCTAssertEqual(doc.data(), data, "\(name) not byte exact")
        }
        // the real config's main file layout (comment + Include lines) and invalid UTF-8 (read-only, still exact)
        let bad = Data([0x50, 0x72, 0x65, 0x61, 0x6D, 0x70, 0x3A, 0x20, 0x2D, 0x31, 0xFF, 0x0A])
        let d = ConfigDocument(data: bad)
        XCTAssertTrue(d.readOnly)
        XCTAssertEqual(d.data(), bad)
        var e = d
        XCTAssertThrowsError(try e.setCommand(.preamp(dB: -2), at: 0))
    }

    func testEncodingAndNewlineDetection() {
        let fx = Dictionary(uniqueKeysWithValues: DocumentTests.fixtures)
        XCTAssertEqual(ConfigDocument(data: fx["rew-crlf"]!).newline, "\r\n")
        XCTAssertEqual(ConfigDocument(data: fx["rew-lf"]!).newline, "\n")
        XCTAssertEqual(ConfigDocument(data: fx["utf8-bom-crlf"]!).encoding, .utf8BOM)
        XCTAssertEqual(ConfigDocument(data: fx["utf16le-crlf"]!).encoding, .utf16LE)
        XCTAssertEqual(ConfigDocument(data: fx["utf16be-lf"]!).encoding, .utf16BE)
        // line count and numbering match APOParser's split
        let doc = ConfigDocument(data: fx["mixed-endings"]!)
        XCTAssertEqual(doc.lines.map { $0.terminator }, ["\r\n", "\n", "\r", "\r", "\r\n", "\n", ""])
    }

    func testLineKinds() {
        let doc = ConfigDocument(text: DocumentTests.rewLF)
        let kinds = doc.lines.map { $0.kind }
        XCTAssertEqual(kinds[0], .unknown(message: "could not parse filter, NOT converted: Filter Settings file"))   // "Filter" prefix, as APO
        XCTAssertEqual(kinds[2], .unknown(message: "unsupported line, NOT converted: Room EQ V5.31.3"))
        XCTAssertEqual(kinds[1], .blank)
        XCTAssertEqual(kinds[9], .command(.filter(FilterLine(label: "", type: "PK", freq: 60.8, gainDB: -8.5, q: 3.634))))
        XCTAssertEqual(kinds[10], .command(.filter(FilterLine(label: "  2", type: "PK", freq: 118, gainDB: -14.8, q: 10.339))))
        XCTAssertEqual(kinds[11], .comment(command: .filter(FilterLine(type: "PK", freq: 167.5, gainDB: -8.6, q: 1.137))))
        XCTAssertEqual(kinds[12], .command(.filter(FilterLine(label: "  1", type: "None"))))
        XCTAssertEqual(kinds[14], .command(.preamp(dB: -1)))
        guard case .command(.graphicEQ(let pts)) = kinds[15] else { return XCTFail() }
        XCTAssertEqual(pts.count, 31); XCTAssertEqual(pts[3], GraphicEQPoint(freq: 40, gainDB: 6.2))
        XCTAssertEqual(kinds[17], .comment(command: nil))   // "# 4th-order Butterworth"
        XCTAssertEqual(kinds[18], .command(.filter(FilterLine(label: " 1", type: "HPQ", freq: 30, q: 0.5412))))
        XCTAssertEqual(ConfigLine(text: "Filter 3: OFF PK Fc 100 Hz Gain 3 dB Q 2").kind,
                       .command(.filter(FilterLine(label: " 3", enabled: false, type: "PK", freq: 100, gainDB: 3, q: 2))))
        XCTAssertEqual(ConfigLine(text: "Channel: L R").kind, .command(.channel(names: ["L", "R"])))
        XCTAssertEqual(ConfigLine(text: "Include: sub\\x (1).txt").kind, .command(.include(path: "sub\\x (1).txt")))
        XCTAssertEqual(ConfigLine(text: "Filter: OFF").kind, .unknown(message: nil))
    }

    // MARK: single-line edits

    func testEditingOneLineTouchesOnlyThatLine() throws {
        for name in ["rew-lf", "rew-crlf", "utf8-bom-crlf", "utf16le-crlf", "utf16be-lf"] {
            let data = Dictionary(uniqueKeysWithValues: DocumentTests.fixtures)[name]!
            var doc = ConfigDocument(data: data)
            let before = doc
            guard case .command(.filter(var f)) = doc.lines[10].kind else { return XCTFail(name) }
            f.gainDB = -12.5
            try doc.setCommand(.filter(f), at: 10)
            XCTAssertEqual(doc.lines[10].text, "Filter 2: ON PK Fc 118 Hz Gain -12.5 dB Q 10.339", name)
            XCTAssertEqual(doc.lines[10].terminator, before.lines[10].terminator, name)
            for i in doc.lines.indices where i != 10 { XCTAssertEqual(doc.lines[i], before.lines[i], "\(name) line \(i)") }
            XCTAssertEqual(doc.encoding, before.encoding)
            // bytes: everything before and after the edited line is identical
            let expected = before.lines[..<10].map { $0.text + $0.terminator }.joined()
                + doc.lines[10].text + doc.lines[10].terminator
                + before.lines[11...].map { $0.text + $0.terminator }.joined()
            XCTAssertEqual(doc.text, expected, name)
            XCTAssertEqual(ConfigDocument(data: doc.data()), doc, "\(name): re-decoding the edited bytes gives the same document")
        }
    }

    func testCanonicalTextReadsBackToSameFields() {
        let cases: [FilterLine] = [
            FilterLine(label: " 1", type: "PK", freq: 60.8, gainDB: -8.5, q: 3.634),
            FilterLine(label: " 2", enabled: false, type: "PEQ", freq: 1000.5, gainDB: 3, q: 0.7),
            FilterLine(type: "Modal", freq: 40, gainDB: -3, q: 10),
            FilterLine(type: "LSC", freq: 100, gainDB: 3, slopeDB: 12),
            FilterLine(type: "HS", freq: 8000, gainDB: -2.25, q: 0.5),
            FilterLine(type: "LS", freq: 105, gainDB: 6),
            FilterLine(type: "HPQ", freq: 30, q: 0.5412),
            FilterLine(type: "LP", freq: 18000),
            FilterLine(type: "NO", freq: 50, q: 30),
            FilterLine(type: "AP", freq: 500, bandwidthOct: 1.5),
            FilterLine(type: "BP", freq: 2000, gainDB: 0, q: 2),
            FilterLine(type: "PK", freq: 60.812, gainDB: -1, q: 1),       // 3 decimals: needs the thousands guard
            FilterLine(type: "PK", freq: 1.234, gainDB: 0.000001, q: 12.5),
            FilterLine(label: " 7", type: "None"),
        ]
        for f in cases {
            let text = ConfigCommand.filter(f).canonicalText
            var want = f
            if let n = f.number { want.label = " \(n)" } else { want.label = "" }
            XCTAssertEqual(ConfigLine(text: text).kind, .command(.filter(want)), text)
        }
        XCTAssertEqual(ConfigCommand.filter(cases[11]).canonicalText, "Filter: ON PK Fc 60.8120 Hz Gain -1 dB Q 1")
        XCTAssertEqual(ConfigCommand.preamp(dB: -1).canonicalText, "Preamp: -1 dB")
        XCTAssertEqual(ConfigCommand.graphicEQ(points: [GraphicEQPoint(freq: 31.5, gainDB: 6.2), GraphicEQPoint(freq: 20000, gainDB: 0)]).canonicalText,
                       "GraphicEQ: 31.5 6.2; 20000 0")
        for c: ConfigCommand in [.preamp(dB: -0.25), .channel(names: ["L"]), .include(path: "a b.txt"),
                                 .graphicEQ(points: [GraphicEQPoint(freq: 20, gainDB: -1.5), GraphicEQPoint(freq: 25, gainDB: 0)])] {
            XCTAssertEqual(ConfigLine(text: c.canonicalText).kind, .command(c))
        }
    }

    func testToggleOnOffPreampAndGraphicEQEdits() throws {
        var doc = ConfigDocument(text: "Preamp: -1 dB\nFilter 1: ON HPQ Fc 30 Hz Q 0.5412\nGraphicEQ: 20 6.2; 40 6.2; 50 0\n")
        guard case .command(.filter(var f)) = doc.lines[1].kind else { return XCTFail() }
        f.enabled = false
        try doc.setCommand(.filter(f), at: 1)
        XCTAssertEqual(doc.lines[1].text, "Filter 1: OFF HPQ Fc 30 Hz Q 0.5412")
        try doc.setCommand(.preamp(dB: -3.5), at: 0)
        try doc.setCommand(.graphicEQ(points: [GraphicEQPoint(freq: 20, gainDB: 3), GraphicEQPoint(freq: 40, gainDB: 3), GraphicEQPoint(freq: 50, gainDB: 0)]), at: 2)
        XCTAssertEqual(doc.text, "Preamp: -3.5 dB\nFilter 1: OFF HPQ Fc 30 Hz Q 0.5412\nGraphicEQ: 20 3; 40 3; 50 0\n")
        let r = APOParser.parse(text: doc.text, baseURL: nil)
        XCTAssertEqual(r.config.left.count, 2)
        XCTAssertEqual(r.config.left[0], .gain(dB: -3.5))
    }

    func testCommentEnableDisable() throws {
        var doc = ConfigDocument(text: DocumentTests.rewCRLF)
        XCTAssertEqual(doc.lines[11].text, "# Filter: ON PK Fc 167.5 Hz Gain -8.6 dB Q 1.137")
        try doc.setCommented(false, at: 11)
        XCTAssertEqual(doc.lines[11].text, "Filter: ON PK Fc 167.5 Hz Gain -8.6 dB Q 1.137")
        XCTAssertEqual(doc.lines[11].terminator, "\r\n")
        let parsed = APOParser.parse(text: doc.text, baseURL: nil).config.left
        XCTAssertEqual(parsed.count, H.fixtureConfig.left.count + 1)
        XCTAssertEqual(parsed[2], H.pk(167.5, -8.6, 1.137))
        // disable an active line and enable it again: the line returns to its text
        let original = doc.lines[9].text
        try doc.setCommented(true, at: 9)
        XCTAssertEqual(doc.lines[9].text, "# " + original)
        try doc.setCommented(false, at: 9)
        XCTAssertEqual(doc.lines[9].text, original)
        // a plain comment cannot be enabled
        XCTAssertThrowsError(try doc.setCommented(false, at: 17)) { XCTAssertEqual($0 as? ConfigDocument.EditError, .notACommandComment) }
        // editing a commented command keeps it commented
        var d2 = ConfigDocument(text: "#Filter: ON PK Fc 100 Hz Gain 1 dB Q 1\n")
        guard case .comment(.some(.filter(var g))) = d2.lines[0].kind else { return XCTFail() }
        g.gainDB = 2
        try d2.setCommand(.filter(g), at: 0)
        XCTAssertEqual(d2.lines[0].text, "# Filter: ON PK Fc 100 Hz Gain 2 dB Q 1")
    }

    func testAddRemoveReorder() throws {
        var doc = ConfigDocument(text: "Preamp: -1 dB\r\nFilter: ON PK Fc 100 Hz Gain 1 dB Q 1\r\n")
        let i = try doc.appendCommand(.filter(FilterLine(type: "PK", freq: 1000, gainDB: -2, q: 2)))
        XCTAssertEqual(i, 2)
        XCTAssertEqual(doc.text, "Preamp: -1 dB\r\nFilter: ON PK Fc 100 Hz Gain 1 dB Q 1\r\nFilter: ON PK Fc 1000 Hz Gain -2 dB Q 2\r\n")
        try doc.moveLine(from: 2, to: 0)
        XCTAssertEqual(doc.text, "Filter: ON PK Fc 1000 Hz Gain -2 dB Q 2\r\nPreamp: -1 dB\r\nFilter: ON PK Fc 100 Hz Gain 1 dB Q 1\r\n")
        try doc.moveLine(from: 0, to: 99 > doc.lines.count ? doc.lines.count - 1 : 0)   // clamped before the final line break
        XCTAssertEqual(doc.text, "Preamp: -1 dB\r\nFilter: ON PK Fc 100 Hz Gain 1 dB Q 1\r\nFilter: ON PK Fc 1000 Hz Gain -2 dB Q 2\r\n")
        try doc.removeLine(at: 1)
        XCTAssertEqual(doc.text, "Preamp: -1 dB\r\nFilter: ON PK Fc 1000 Hz Gain -2 dB Q 2\r\n")
        // a file without a final line break keeps having none
        var d2 = ConfigDocument(text: "Preamp: -1 dB")
        try d2.appendCommand(.preamp(dB: -2))
        XCTAssertEqual(d2.text, "Preamp: -1 dB\nPreamp: -2 dB")
        try d2.moveLine(from: 1, to: 0)
        XCTAssertEqual(d2.text, "Preamp: -2 dB\nPreamp: -1 dB")
        try d2.removeLine(at: 1)
        XCTAssertEqual(d2.text, "Preamp: -2 dB")
        var empty = ConfigDocument(data: Data())
        try empty.appendCommand(.preamp(dB: 0))
        XCTAssertEqual(empty.text, "Preamp: 0 dB\n")   // an empty file is one empty line: the new line goes before it
    }

    // MARK: workspace: includes, evaluation, undo

    func makeIncludeTree() throws -> URL {
        try write("sub dir/inner (x).txt", Data([0xFF, 0xFE]) + "Channel: R\r\nFilter 1: ON PK Fc 1000 Hz Gain -3 dB Q 1\r\nInclude: ..\\deep.txt\r\n".data(using: .utf16LittleEndian)!)
        try writeText("deep.txt", "Preamp: -0.5 dB\n")
        return try writeText("config.txt", "# main\nPreamp: -2 dB\nInclude: sub dir\\inner (x).txt\nInclude: missing.txt\nFilter: ON PK Fc 100 Hz Gain 2 dB Q 1\n")
    }

    func testIncludeTreeAndEvaluationMatchParser() throws {
        let main = try makeIncludeTree()
        let ws = try ConfigWorkspace(rootURL: main)
        XCTAssertEqual(ws.documents.count, 3)
        let tree = ws.includeTree()
        XCTAssertEqual(tree.children.map { $0.pathAsWritten }, ["sub dir\\inner (x).txt", "missing.txt"])
        XCTAssertEqual(tree.children[0].children.first?.url.lastPathComponent, "deep.txt")
        XCTAssertFalse(tree.children[1].exists)
        XCTAssertEqual(tree.children[0].includedFrom, LineRef(url: ws.rootURL, line: 2))

        let ev = ws.evaluate()
        let ref = try APOParser.parse(fileURL: main)
        XCTAssertEqual(ev.result.config, ref.config)
        XCTAssertEqual(ev.result.warnings, ref.warnings)
        XCTAssertEqual(ev.leftOrigins.count, ev.result.config.left.count)
        XCTAssertEqual(ev.rightOrigins.count, ev.result.config.right.count)
        XCTAssertEqual(ev.warningRefs.count, ev.result.warnings.count)
        // the PK in the included file is right-only and attributed to that file's line 1
        let inner = ConfigWorkspace.key(dir.appendingPathComponent("sub dir/inner (x).txt"))
        XCTAssertEqual(ev.stages(of: LineRef(url: inner, line: 1)).right, [H.pk(1000, -3, 1)])
        XCTAssertEqual(ev.stages(of: LineRef(url: inner, line: 1)).left, [])
        XCTAssertEqual(ev.lineChannels[LineRef(url: inner, line: 1)], [1])
        XCTAssertEqual(ev.lineChannels[LineRef(url: ws.rootURL, line: 4)], [0, 1], "channel selection restored after the include")
        XCTAssertTrue(ev.warningRefs.contains(LineRef(url: ws.rootURL, line: 3)), "missing-include warning points at its line")
    }

    func testIncludeCycle() throws {
        // Equalizer APO follows a self-include until its recursion limit; the tree shows it once, marked as a cycle
        let main = try writeText("loop.txt", "Preamp: -1 dB\nInclude: \"loop.txt\"\n")
        let ws = try ConfigWorkspace(rootURL: main)
        XCTAssertTrue(ws.includeTree().children[0].isCycle)
        let ref = try APOParser.parse(fileURL: main)
        XCTAssertEqual(ws.evaluate().result.config, ref.config)
        XCTAssertEqual(ws.evaluate().result.warnings, ref.warnings)
        XCTAssertEqual(ref.config.left.count, 101)
    }

    func testEditingIncludedFileOnlyChangesThatDocument() throws {
        let main = try makeIncludeTree()
        let ws = try ConfigWorkspace(rootURL: main)
        let inner = ConfigWorkspace.key(dir.appendingPathComponent("sub dir/inner (x).txt"))
        let rootBefore = ws.root
        XCTAssertTrue(ws.edit(inner, name: "Gain") { doc in
            guard case .command(.filter(var f)) = doc.lines[1].kind else { return }
            f.gainDB = -6
            try doc.setCommand(.filter(f), at: 1)
        })
        XCTAssertEqual(ws.root, rootBefore)
        let d = try XCTUnwrap(ws.document(inner))
        XCTAssertEqual(d.encoding, .utf16LE)
        XCTAssertEqual(d.lines[1].text, "Filter 1: ON PK Fc 1000 Hz Gain -6 dB Q 1")
        XCTAssertEqual(d.lines[1].terminator, "\r\n")
        // writing it out and parsing from disk equals the in-memory evaluation
        try d.data().write(to: inner)
        XCTAssertEqual(ws.evaluate().result.config, try APOParser.parse(fileURL: main).config)
        XCTAssertEqual(ws.modifiedSinceOpen, [inner])
    }

    func testUndoRedoAndCoalescing() throws {
        let main = try writeText("c.txt", "Preamp: -1 dB\nFilter: ON PK Fc 100 Hz Gain 1 dB Q 1\n")
        let ws = try ConfigWorkspace(rootURL: main)
        let original = ws.root
        // a drag: many edits, one undo step
        for g in stride(from: 1.5, through: 6, by: 0.5) {
            ws.edit(main, name: "Gain", coalesceKey: "drag-1") { doc in
                try doc.setCommand(.filter(FilterLine(type: "PK", freq: 100, gainDB: g, q: 1)), at: 1)
            }
        }
        ws.endCoalescing()
        ws.edit(main, name: "Preamp") { try $0.setCommand(.preamp(dB: -4), at: 0) }
        XCTAssertEqual(ws.undoStack.count, 2)
        XCTAssertEqual(ws.root.text, "Preamp: -4 dB\nFilter: ON PK Fc 100 Hz Gain 6 dB Q 1\n")
        XCTAssertEqual(ws.undo(), [ConfigWorkspace.key(main)])
        XCTAssertEqual(ws.root.text, "Preamp: -1 dB\nFilter: ON PK Fc 100 Hz Gain 6 dB Q 1\n")
        ws.undo()
        XCTAssertEqual(ws.root, original)
        XCTAssertNil(ws.undo())
        ws.redo(); ws.redo()
        XCTAssertEqual(ws.root.text, "Preamp: -4 dB\nFilter: ON PK Fc 100 Hz Gain 6 dB Q 1\n")
        XCTAssertNil(ws.redo())
        // a new edit clears redo; revert is one undoable step back to the bytes at open
        ws.undo()
        ws.edit(main) { try $0.appendCommand(.preamp(dB: 1)) }
        XCTAssertFalse(ws.canRedo)
        ws.revertToOriginals()
        XCTAssertEqual(ws.root.data(), try Data(contentsOf: main))
        ws.undo()
        XCTAssertNotEqual(ws.root, original)
        // a no-op edit is not recorded
        let n = ws.undoStack.count
        XCTAssertFalse(ws.edit(main) { _ in })
        XCTAssertEqual(ws.undoStack.count, n)
    }

    func testNewIncludeLineLoadsTheFile() throws {
        try writeText("extra.txt", "Preamp: -3 dB\n")
        let main = try writeText("c.txt", "Preamp: -1 dB\n")
        let ws = try ConfigWorkspace(rootURL: main)
        XCTAssertEqual(ws.documents.count, 1)
        ws.edit(main) { try $0.appendCommand(.include(path: "extra.txt")) }
        XCTAssertEqual(ws.documents.count, 2)
        XCTAssertEqual(ws.evaluate().result.config.left, [.gain(dB: -1), .gain(dB: -3)])
    }

    // MARK: stage equality with APOParser on every syntax case of the parser tests

    static let syntaxCases: [String] = [
        H.fixtureText, rewCRLF,
        "Filter: ON PK Fc 1000 Hz Gain 3 dB Q 2", "Filter: ON PEQ Fc 1000 Hz Gain 3 dB Q 2",
        "Filter: ON LSC Fc 100 Hz Gain 3 dB Q 0.7", "Filter: ON HSC Fc 8000 Hz Gain -3 dB",
        "Filter: ON HSC 6 dB Fc 8000 Hz Gain -3 dB", "Filter: ON HSC 12 dB Fc 8000 Hz Gain -3 dB",
        "Filter: ON LS Fc 100 Hz Gain 3 dB", "Filter: ON HS Fc 100 Hz Gain 3 dB", "Filter: ON LP Fc 100 Hz",
        "Filter: ON HP Fc 100 Hz", "Filter: ON LPQ Fc 100 Hz Q 1.2", "Filter: ON HPQ Fc 100 Hz Q 1.2",
        "Filter: ON NO Fc 50 Hz", "Filter: ON AP Fc 50 Hz Q 2", "Filter: ON BP Fc 50 Hz Q 2",
        "Filter: OFF PK Fc 1000 Hz Gain 3 dB Q 2\nFilter 3: ON None\n# Filter: ON PK Fc 1 Hz Gain 1 dB Q 1\n",
        "Filter: ON XYZ Fc 1000 Hz\nFilter: ON PK Gain 3 dB Q 1\nSomething: else\nGraphicEQ: 20 1",
        "Filter: ON PK Fc 1000,5 Hz Gain -3,5 dB Q 1,5", "Preamp: -2,5 dB\nGraphicEQ: 20 1,5; 100 -2,5",
        "Filter: ON PK Fc 1000 Hz Gain 3 dB BW Oct 1",
        "Preamp: -3 dB\nFilter: ON PK Fc 100 Hz Gain 1 dB Q 1\nPreamp: -1 dB\nGraphicEQ: 100 0; 20 3",
        "Filter: ON PK Fc 100 Hz Gain 1 dB Q 1\nChannel: L\nFilter: ON PK Fc 200 Hz Gain 2 dB Q 1\nChannel: R\nPreamp: -4 dB\nChannel: ALL\nPreamp: -1 dB",
        "Channel: L R\nPreamp: -1 dB\nChannel: C\nPreamp: -9 dB",
        "Preamp: -2 dB\r\nFilter: ON PK Fc 100 Hz Gain 1 dB Q 1\r\n",
        "Filter: ON PEQ Fc 1000 Hz Gain 6 dB BW Oct 0.5", "Filter: ON PK Fc 1000 Hz Gain 6 dB Q 5 BW Oct 0.5",
        "Filter: ON PK Fc 1000 Hz Gain 6 dB BW 0.5", "Filter: ON LS Fc 100 Hz Gain 6 dB",
        "Filter: ON LS 12 dB Fc 100 Hz Gain 6 dB", "Filter: ON HS 6dB Fc 1000 Hz Gain -6 dB",
        "Filter: ON LS Fc 100 Hz Gain 6 dB Q 0.5", "Filter: ON LSC 12 dB Fc 100 Hz Gain 6 dB",
        "Filter: ON HSC Fc 100 Hz Gain 6 dB Q 0.5", "Filter: ON LSC Fc 100 Hz Gain 3 dB BW Oct 1",
        "Filter: ON LSC 6 dB Fc 100 Hz Gain 3 dB Q 2", "Filter: ON PK Fc 100 Hz Gain 3 dB", "Filter: ON AP Fc 100 Hz",
        "Filter: ON PK Fc 100 Hz Q 2", "Filter: ON LS Fc 100 Hz", "Filter: ON HP Fc 100 Hz Gain 3 dB",
        "preamp: -3 dB", "Filter: ON pk Fc 100 Hz Gain 3 dB Q 1", "Filter: on PK Fc 100 Hz Gain 3 dB Q 1",
        "Filter: ON PK fc 100 hz Gain 3 dB Q 1", "Filter: ON Modal Fc 100 Hz Gain 3 dB Q 1",
        "Filter: ON MODAL Fc 100 Hz Gain 3 dB Q 1", "Channel: l\nPreamp: -1 dB", "Channel: all\nPreamp: -1 dB",
        "Preamp: -6 db", "Preamp: -6", "Preamp: .5 dB", "Preamp: +1,5 dB", "Preamp: loud dB",
        "Filter: ON PK Fc 1.000 Hz Gain 3 dB Q 1", "Filter: ON PK Fc 2,500 Hz Gain 3 dB Q 1",
        "Filter: ON PK Fc 118.0 Hz Gain 3 dB Q 1", "Filter: ON PK Fc 60.8 Hz Gain 3 dB Q 1",
        "Filter: ON PK Fc 1e3 Hz Gain 3 dB Q 1", "GraphicEQ:20 1;30 2 ;  40\t3;", "GraphicEQ: 20 1 30 2 40 3",
        "GraphicEQ: 40 3; 20 1; 30 2", "GraphicEQ: 20 1,5; 30 2",
        "Channel: 1\nPreamp: -1 dB\nChannel: 2\nPreamp: -2 dB\nChannel: 1 2\nPreamp: -3 dB",
        "Filter: ON IIR Order 2 Coefficients 1 0 0 1 0 0", "Filter: OFF IIR x", "Filter: OFF", "Filter 1: OFF None",
        "Device: Scarlett\nStage: post-mix\nCopy: L=R\nDelay: 5 ms\nIf: sampleRate == 48000\nEndIf:",
        "Filter: ON LS 12 dB Fc 100 Hz Gain 0 dB", "Filter: ON PK Fc 0 Hz Gain 3 dB Q 1", "Filter: ON PK Fc -5 Hz Gain 3 dB Q 1",
        "  \tPreamp:\t-1 dB  \n\n#\n#   \n", "Include: nothing-here.txt", "Channel:\nPreamp: -1 dB",
    ]

    func testStagesEqualAPOParserOnAllSyntaxCases() throws {
        for (i, text) in DocumentTests.syntaxCases.enumerated() {
            let u = try writeText("case-\(i).txt", text)
            let ref = try APOParser.parse(fileURL: u)
            let ev = try ConfigWorkspace(rootURL: u).evaluate()
            XCTAssertEqual(ev.result.config, ref.config, "case \(i): \(text.prefix(60))")
            XCTAssertEqual(ev.result.warnings, ref.warnings, "case \(i): \(text.prefix(60))")
            XCTAssertEqual(ev.leftOrigins.count, ref.config.left.count)
            // and the per-line kinds agree with the text API too
            XCTAssertEqual(APOParser.parse(text: ConfigDocument(text: text).text, baseURL: nil).config, ref.config)
        }
        // encodings
        for (name, data) in DocumentTests.fixtures {
            let u = try write("fx-\(name).txt", data)
            XCTAssertEqual(try ConfigWorkspace(rootURL: u).evaluate().result.config, try APOParser.parse(fileURL: u).config, name)
        }
    }

    func testRealConfigCopyIfPresent() throws {
        guard let url = H.realFiles() else { throw XCTSkip("set EQAPE_REAL_CONFIG to a copy of a real config") }
        let ws = try ConfigWorkspace(rootURL: url)
        XCTAssertEqual(ws.evaluate().result.config, try APOParser.parse(fileURL: url).config)
        XCTAssertEqual(ws.evaluate().result.warnings, try APOParser.parse(fileURL: url).warnings)
        for (u, d) in ws.documents { XCTAssertEqual(d.data(), try Data(contentsOf: u), u.lastPathComponent) }
    }
}
