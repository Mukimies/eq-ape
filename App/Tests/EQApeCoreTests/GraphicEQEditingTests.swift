import EQCore
import Foundation
import XCTest
@testable import EQApeCore

final class GraphicEQEditingTests: XCTestCase {
    typealias E = GraphicEQEditing
    func P(_ f: Double, _ g: Double) -> GraphicEQPoint { GraphicEQPoint(freq: f, gainDB: g) }
    var five: [GraphicEQPoint] { [P(20, 0), P(100, 3), P(1000, -2), P(10000, 1), P(20000, 0)] }

    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("EQApeGEQ-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func waitUntil(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return true }; RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return cond()
    }

    // MARK: node operations

    func testMoveNodeSidewaysAndVerticallyWithRounding() {
        let n = E.moveNode(five, index: 2, freq: 1234.567, gain: -4.26)
        XCTAssertEqual(n[2], P(1230, -4.3))
        XCTAssertEqual(n.count, 5)
        // below 100 Hz the step is 0.1 Hz
        XCTAssertEqual(E.moveNode(five, index: 1, freq: 63.04, gain: 3)[1].freq, 63)
        XCTAssertEqual(E.moveNode(five, index: 1, freq: 31.46, gain: 3)[1].freq, 31.5)
        // an unchanged component is not rewritten (a click does not round typed values)
        let typed = [P(20, 0), P(123.45, 1.234), P(20000, 0)]
        XCTAssertEqual(E.moveNode(typed, index: 1, freq: 123.45, gain: 2)[1], P(123.45, 2))
        XCTAssertEqual(E.moveNode(typed, index: 1, freq: 150, gain: 1.234)[1], P(150, 1.234))
    }

    func testMoveNodeClampsAndKeepsOrder() {
        // cannot pass the right neighbour (1000 Hz): stops just below it with the minimum spacing
        let a = E.moveNode(five, index: 1, freq: 5000, gain: 3)
        XCTAssertLessThan(a[1].freq, 1000)
        XCTAssertLessThanOrEqual(a[1].freq * E.minRatio, 1000 + 1e-9)
        XCTAssertGreaterThan(a[1].freq, 980)
        XCTAssertEqual(a.map(\.freq), a.map(\.freq).sorted())
        // nor the left one
        let b = E.moveNode(five, index: 2, freq: 30, gain: -2)
        XCTAssertGreaterThanOrEqual(b[2].freq, 100 * E.minRatio - 1e-9)
        XCTAssertLessThan(b[2].freq, 103)
        // ends: frequency and gain ranges
        XCTAssertEqual(E.moveNode(five, index: 0, freq: 0.01, gain: -99)[0], P(1, -30))
        XCTAssertEqual(E.moveNode(five, index: 4, freq: 1e6, gain: 99)[4], P(24000, 30))
        // neighbours too close for any movement: frequency unchanged
        let tight = [P(100, 0), P(100.5, 0), P(101, 0)]
        XCTAssertEqual(E.moveNode(tight, index: 1, freq: 200, gain: 0)[1].freq, 100.5)
        // ordering survives a long random walk of drags
        var p = five
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let i = Int.random(in: 0..<p.count, using: &rng)
            p = E.moveNode(p, index: i, freq: p[i].freq * pow(2, Double.random(in: -3...3, using: &rng)), gain: Double.random(in: -40...40, using: &rng))
            for k in 1..<p.count { XCTAssertGreaterThanOrEqual(p[k].freq / p[k - 1].freq, E.minRatio - 1e-9) }
        }
    }

    func testAddAndRemoveNode() throws {
        let r = try XCTUnwrap(E.addNode(five, freq: 316.2))
        XCTAssertEqual(r.index, 2)
        XCTAssertEqual(r.points[2].freq, 316)
        XCTAssertEqual(r.points[2].gainDB, E.roundGain(GraphicEQDesigner.interpolateDB(five, 316)))
        XCTAssertLessThan(E.maxDifference(five, r.points), 0.06, "adding a node keeps the curve (gain rounded to 0.1 dB)")
        XCTAssertNil(E.addNode(five, freq: 1003), "rounds to 1000 Hz, an existing node")
        XCTAssertNil(E.addNode(five, freq: 1004.9, round: false), "within the minimum spacing")
        XCTAssertEqual(E.addNode(five, freq: 10)?.index, 0)
        XCTAssertEqual(E.addNode(five, freq: 10)?.points[0], P(10, 0))
        // remove, but keep at least two
        var p = five
        p = try XCTUnwrap(E.removeNode(p, index: 1)); XCTAssertEqual(p.map(\.freq), [20, 1000, 10000, 20000])
        p = try XCTUnwrap(E.removeNode(p, index: 0))
        p = try XCTUnwrap(E.removeNode(p, index: 0))
        XCTAssertEqual(p.count, 2)
        XCTAssertNil(E.removeNode(p, index: 0))
    }

    // MARK: layouts

    func testLayoutDetectionAndConversion() {
        let flat31 = E.fixed31.map { P($0, 0) }
        XCTAssertEqual(E.layout(of: flat31), .fixed31)
        XCTAssertEqual(E.layout(of: E.fixed15.map { P($0, 1) }), .fixed15)
        XCTAssertEqual(E.layout(of: E.defaultVariable), .variable)
        XCTAssertEqual(E.layout(of: flat31.reversed()), .fixed31, "file order does not matter")
        // the owner-like 31-band curve is detected as fixed
        let bass1 = [20, 25, 31.5, 40].map { P($0, 6.2) } + E.fixed31.dropFirst(4).map { P($0, 0) }
        XCTAssertEqual(E.layout(of: bass1), .fixed31)
        // fixed -> variable keeps the points (it is only a mode; a node can then move)
        let moved = E.moveNode(bass1, index: 3, freq: 44, gain: 6.2)
        XCTAssertEqual(moved[3].freq, 44)
        XCTAssertEqual(E.layout(of: moved), .variable)
        // variable -> fixed resamples the curve at the band frequencies
        let v = [P(20, 0), P(100, 6), P(1000, 0), P(20000, 0)]
        let f15 = E.resample(v, to: E.fixed15)
        XCTAssertEqual(f15.map(\.freq), E.fixed15)
        XCTAssertEqual(f15[3], P(100, 6))
        XCTAssertEqual(f15[0].gainDB, E.roundGain(GraphicEQDesigner.interpolateDB(v, 25)))
        XCTAssertEqual(E.layout(of: f15), .fixed15)
        // the conversion changes the response where the old curve had detail between the bands
        let spiky = [P(20, 0), P(120, 0), P(130, 9), P(140, 0), P(20000, 0)]
        XCTAssertGreaterThan(E.maxDifference(spiky, E.resample(spiky, to: E.fixed15)), 5)
        XCTAssertEqual(E.maxDifference(flat31, E.resample(flat31, to: E.fixed31)), 0)
    }

    // MARK: file format

    func testNumberFormattingRoundTrip() throws {
        // dragged values are rounded to short decimals, typed ones are kept; no trailing zeros
        var p = E.moveNode(E.defaultVariable, index: 1, freq: 63.04999, gain: 4.04999)
        p = E.moveNode(p, index: 2, freq: 1234.5, gain: -2.5, round: false)
        p = E.moveNode(p, index: 3, freq: 12345.678, gain: 0.00001)
        let text = ConfigCommand.graphicEQ(points: p).canonicalText
        XCTAssertEqual(text, "GraphicEQ: 20 0; 63 4; 1234.5 -2.5; 12300 0; 20000 0")
        let back = try XCTUnwrap(ConfigLine(text: text).kind.command)
        XCTAssertEqual(back, .graphicEQ(points: p))
        // values that need precision survive exactly
        let precise = [P(31.5, 6.2), P(60.812, -1.05), P(1000.25, 0.1), P(19999.9, -0.3)]
        let t2 = ConfigCommand.graphicEQ(points: precise).canonicalText
        XCTAssertEqual(t2, "GraphicEQ: 31.5 6.2; 60.812 -1.05; 1000.25 0.1; 19999.9 -0.3")
        XCTAssertEqual(APOParser.parse(text: t2, baseURL: nil).config.left, [.graphicEQ(points: precise)])
        // every value a drag can produce prints shortly (no 31.500000000000004)
        var f = 1.0
        while f < 24000 {
            let s = APOFormat.number(E.roundFreq(f))
            XCTAssertLessThanOrEqual(s.count, 6, s)
            f *= 1.013
        }
        for g in stride(from: -30.0, through: 30, by: 0.037) { XCTAssertLessThanOrEqual(APOFormat.number(E.roundGain(g)).count, 5) }
    }

    // MARK: through the editing session (undo, live save, file = model)

    func testDragUndoGranularityAndFileMatchesModel() throws {
        let original = "# room\r\nPreamp: -2 dB\r\nGraphicEQ: 20 0; 100 3; 1000 -2; 10000 1; 20000 0\r\nFilter 1: ON PK Fc 60 Hz Gain -3 dB Q 2\r\n"
        let url = dir.appendingPathComponent("c.txt")
        try Data(original.utf8).write(to: url)
        let s = try ConfigEditSession(rootURL: url, backups: EditorBackups(baseDirectory: dir.appendingPathComponent("B")))
        let ref = LineRef(url: url, line: 2)
        let key = "geqnode-\(url.path)-2"
        // one drag gesture: 30 move steps -> one undo step
        let start = try XCTUnwrap(s.graphicEQPoints(at: ref))
        for k in 1...30 {
            let pts = try XCTUnwrap(s.graphicEQPoints(at: ref))
            s.setGraphicEQ(E.moveNode(pts, index: 1, freq: 100 * pow(2, Double(k) / 20), gain: 3 + Double(k) * 0.1), at: ref,
                           name: "Drag Graphic EQ Node", coalesceKey: key)
        }
        s.endCoalescing()
        XCTAssertEqual(s.workspace.undoStack.count, 1)
        // a second gesture on the same line is a second step
        s.setGraphicEQ(E.moveNode(try XCTUnwrap(s.graphicEQPoints(at: ref)), index: 3, freq: 8000, gain: 1), at: ref, coalesceKey: key)
        s.endCoalescing()
        XCTAssertEqual(s.workspace.undoStack.count, 2)
        // add and remove: one step each
        let added = try XCTUnwrap(E.addNode(try XCTUnwrap(s.graphicEQPoints(at: ref)), freq: 3000))
        s.setGraphicEQ(added.points, at: ref, name: "Add Graphic EQ Node")
        let removed = try XCTUnwrap(E.removeNode(try XCTUnwrap(s.graphicEQPoints(at: ref)), index: 0))
        s.setGraphicEQ(removed, at: ref, name: "Remove Graphic EQ Node")
        XCTAssertEqual(s.workspace.undoStack.count, 4)
        XCTAssertFalse(s.setGraphicEQ([P(100, 0)], at: ref), "a GraphicEQ line keeps two points")

        // live save: file on disk, only that line changed (CRLF and other lines byte-identical)
        XCTAssertTrue(waitUntil(2) { s.pending.isEmpty })
        let disk = try String(contentsOf: url, encoding: .utf8)
        let lines = disk.components(separatedBy: "\r\n")
        let origLines = original.components(separatedBy: "\r\n")
        XCTAssertEqual(lines.count, origLines.count)
        for i in lines.indices where i != 2 { XCTAssertEqual(lines[i], origLines[i]) }
        XCTAssertEqual(lines[2], "GraphicEQ: 283 6; 1000 -2; 3000 -0.4; 8000 1; 20000 0")
        // stages parsed from the edited file equal the editor's in-memory model
        let model = try XCTUnwrap(s.graphicEQPoints(at: ref))
        let fromDisk = ConfigLoader.load(path: url.path).config
        XCTAssertEqual(fromDisk, s.workspace.evaluate().result.config)
        XCTAssertTrue(fromDisk?.left.contains(.graphicEQ(points: model)) == true)
        XCTAssertEqual(try APOParser.parse(fileURL: url).config.left[1], .graphicEQ(points: model))
        XCTAssertNotEqual(model, start)

        // undo back to the original bytes
        while s.workspace.canUndo { s.undo() }
        s.flush()
        XCTAssertEqual(try Data(contentsOf: url), Data(original.utf8))
    }
}
