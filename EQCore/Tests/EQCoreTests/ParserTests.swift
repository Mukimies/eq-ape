import XCTest
@testable import EQCore

final class ParserTests: XCTestCase {

    func expectedRealStages() -> [Stage] {
        func pts(_ boost: Double, upTo: Double) -> [GraphicEQPoint] {
            let fs: [Double] = [20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800, 1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000, 20000]
            return fs.map { GraphicEQPoint(freq: $0, gainDB: $0 <= upTo ? boost : 0) }
        }
        return [
            H.pk(60.8, -8.5, 3.634), H.pk(118, -14.8, 10.339), .gain(dB: -1),
            .graphicEQ(points: pts(6.2, upTo: 40)), .graphicEQ(points: pts(5, upTo: 80)),
            H.hp(30, 0.5412), H.hp(30, 1.3066),
        ]
    }

    func testRealConfigFile() throws {
        guard let url = H.realFiles() else { throw XCTSkip("real config not present") }
        let r = try APOParser.parse(fileURL: url)
        XCTAssertEqual(r.config.left, expectedRealStages())
        XCTAssertEqual(r.config.right, expectedRealStages())
        XCTAssertFalse(r.warnings.contains { $0.contains("#") && $0.contains("Filter: ON PK Fc 167.5") })
        XCTAssertFalse(r.warnings.contains { $0.contains("167.5") })
        XCTAssertFalse(r.warnings.isEmpty)   // REW header lines
        XCTAssertFalse(r.warnings.contains { $0.contains("not found") })
    }

    func testFixtureText() {
        let r = APOParser.parse(text: H.fixtureText, baseURL: nil)
        XCTAssertEqual(r.config.left, expectedRealStages())
        XCTAssertEqual(r.config.right, expectedRealStages())
        for needle in ["Room EQ V5.31.3", "Dated", "Notes", "Equaliser", "L+R base", "Filter Settings file"] {
            XCTAssertTrue(r.warnings.contains { $0.contains(needle) }, "expected a warning for \(needle)")
        }
        XCTAssertFalse(r.warnings.contains { $0.contains("167.5") })
    }

    func p(_ s: String) -> ParseResult { APOParser.parse(text: s, baseURL: nil) }

    func bq(_ r: ParseResult) -> BiquadSpec {
        guard case .biquad(let b) = r.config.left.first else { XCTFail("no biquad"); return BiquadSpec(kind: .peaking, freq: 0) }
        return b
    }

    func testFilterTypes() {
        XCTAssertEqual(bq(p("Filter: ON PK Fc 1000 Hz Gain 3 dB Q 2")), BiquadSpec(kind: .peaking, freq: 1000, gainDB: 3, q: 2))
        XCTAssertEqual(bq(p("Filter: ON PEQ Fc 1000 Hz Gain 3 dB Q 2")).kind, .peaking)
        XCTAssertEqual(bq(p("Filter: ON LSC Fc 100 Hz Gain 3 dB Q 0.7")), BiquadSpec(kind: .lowShelf, freq: 100, gainDB: 3, q: 0.7))
        XCTAssertEqual(bq(p("Filter: ON HSC Fc 8000 Hz Gain -3 dB")), BiquadSpec(kind: .highShelf, freq: 8000, gainDB: -3, slopeDBPerOct: 10.8))   // CHANGED: APO default S = 0.9 (BiQuadFilterFactory.cpp), was 12 dB/oct
        XCTAssertEqual(bq(p("Filter: ON HSC 6 dB Fc 8000 Hz Gain -3 dB")).slopeDBPerOct, 6)
        XCTAssertEqual(bq(p("Filter: ON HSC 12 dB Fc 8000 Hz Gain -3 dB")), BiquadSpec(kind: .highShelf, freq: 8000, gainDB: -3, slopeDBPerOct: 12))
        let ls = p("Filter: ON LS Fc 100 Hz Gain 3 dB")
        XCTAssertEqual(bq(ls).kind, .lowShelf); XCTAssertEqual(ls.warnings.count, 0)   // CHANGED: APO applies no corner shift to default-slope LS, so no warning is needed
        XCTAssertEqual(bq(p("Filter: ON HS Fc 100 Hz Gain 3 dB")).kind, .highShelf)
        XCTAssertEqual(bq(p("Filter: ON LP Fc 100 Hz")), BiquadSpec(kind: .lowPass, freq: 100, q: 0.5.squareRoot()))   // CHANGED: APO uses M_SQRT1_2, not 0.7071
        XCTAssertEqual(bq(p("Filter: ON HP Fc 100 Hz")), BiquadSpec(kind: .highPass, freq: 100, q: 0.5.squareRoot()))   // CHANGED: APO uses M_SQRT1_2, not 0.7071
        XCTAssertEqual(bq(p("Filter: ON LPQ Fc 100 Hz Q 1.2")).q, 1.2)
        XCTAssertEqual(bq(p("Filter: ON HPQ Fc 100 Hz Q 1.2")).kind, .highPass)
        XCTAssertEqual(bq(p("Filter: ON NO Fc 50 Hz")), BiquadSpec(kind: .notch, freq: 50, q: 30))
        XCTAssertEqual(bq(p("Filter: ON AP Fc 50 Hz Q 2")), BiquadSpec(kind: .allPass, freq: 50, q: 2))
        XCTAssertEqual(bq(p("Filter: ON BP Fc 50 Hz Q 2")), BiquadSpec(kind: .bandPass, freq: 50, q: 2))
    }

    func testSkippedAndWarned() {
        let r = p("Filter: OFF PK Fc 1000 Hz Gain 3 dB Q 2\nFilter 3: ON None\n# Filter: ON PK Fc 1 Hz Gain 1 dB Q 1\n")
        XCTAssertTrue(r.config.left.isEmpty); XCTAssertTrue(r.warnings.isEmpty)
        let w = p("Filter: ON XYZ Fc 1000 Hz\nFilter: ON PK Gain 3 dB Q 1\nSomething: else\nGraphicEQ: 20 1")
        XCTAssertTrue(w.config.left.isEmpty)
        XCTAssertEqual(w.warnings.count, 4)
    }

    func testDecimalCommaAndBandwidth() {
        let b = bq(p("Filter: ON PK Fc 1000,5 Hz Gain -3,5 dB Q 1,5"))
        XCTAssertEqual(b.freq, 1000.5); XCTAssertEqual(b.gainDB, -3.5); XCTAssertEqual(b.q, 1.5)
        let c = p("Preamp: -2,5 dB\nGraphicEQ: 20 1,5; 100 -2,5")
        XCTAssertEqual(c.config.left[0], .gain(dB: -2.5))
        XCTAssertEqual(c.config.left[1], .graphicEQ(points: [GraphicEQPoint(freq: 20, gainDB: 1.5), GraphicEQPoint(freq: 100, gainDB: -2.5)]))
        // CHANGED: APO does not convert BW to Q; it uses alpha = sin(w) sinh(ln2/2 BW w/sin w) (BiQuad.cpp)
        let bw = bq(p("Filter: ON PK Fc 1000 Hz Gain 3 dB BW Oct 1"))
        XCTAssertEqual(bw.bandwidthOct, 1); XCTAssertNil(bw.q)
    }

    func testPreampOrderAndGraphicSort() {
        let r = p("Preamp: -3 dB\nFilter: ON PK Fc 100 Hz Gain 1 dB Q 1\nPreamp: -1 dB\nGraphicEQ: 100 0; 20 3")
        XCTAssertEqual(r.config.left.count, 4)
        XCTAssertEqual(r.config.left[0], .gain(dB: -3)); XCTAssertEqual(r.config.left[2], .gain(dB: -1))
        guard case .graphicEQ(let pts) = r.config.left[3] else { return XCTFail() }
        XCTAssertEqual(pts.first?.freq, 20)
    }

    func testChannels() {
        let r = p("Filter: ON PK Fc 100 Hz Gain 1 dB Q 1\nChannel: L\nFilter: ON PK Fc 200 Hz Gain 2 dB Q 1\nChannel: R\nPreamp: -4 dB\nChannel: ALL\nPreamp: -1 dB")
        XCTAssertEqual(r.config.left.count, 3)
        XCTAssertEqual(r.config.right.count, 3)
        XCTAssertNotEqual(r.config.left, r.config.right)
        XCTAssertEqual(r.config.left[1], H.pk(200, 2, 1)); XCTAssertEqual(r.config.right[1], .gain(dB: -4))
        XCTAssertEqual(r.config.left[2], .gain(dB: -1)); XCTAssertEqual(r.config.right[2], .gain(dB: -1))
        let r2 = p("Channel: L R\nPreamp: -1 dB\nChannel: C\nPreamp: -9 dB")
        XCTAssertEqual(r2.config.left, [.gain(dB: -1)]); XCTAssertEqual(r2.warnings.count, 1)
    }

    func testEncodingsAndCRLF() {
        let body = "Preamp: -2 dB\r\nFilter: ON PK Fc 100 Hz Gain 1 dB Q 1\r\n"
        let utf8bom = Data([0xEF, 0xBB, 0xBF]) + Data(body.utf8)
        var u16le = Data([0xFF, 0xFE]); u16le.append(body.data(using: .utf16LittleEndian)!)
        var u16be = Data([0xFE, 0xFF]); u16be.append(body.data(using: .utf16BigEndian)!)
        for d in [utf8bom, u16le, u16be, Data(body.utf8)] {
            let r = APOParser.parse(text: APOParser.decode(d), baseURL: nil)
            XCTAssertEqual(r.config.left, [.gain(dB: -2), H.pk(100, 1, 1)])
            XCTAssertTrue(r.warnings.isEmpty, "\(r.warnings)")
        }
    }

    func testIncludeRelativeWithSpacesAndFileParse() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eqcore-\(UUID().uuidString)")
        let sub = dir.appendingPathComponent("sub dir")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "Preamp: -2 dB\r\nInclude: deeper (x).txt".write(to: sub.appendingPathComponent("my file (1).txt"), atomically: true, encoding: .utf8)
        var d = Data([0xFF, 0xFE]); d.append("Filter: ON PK Fc 100 Hz Gain 1 dB Q 1".data(using: .utf16LittleEndian)!)
        try d.write(to: sub.appendingPathComponent("deeper (x).txt"))
        try "Include: sub dir\\my file (1).txt\nInclude: missing.txt\n".write(to: dir.appendingPathComponent("main.txt"), atomically: true, encoding: .utf8)
        let r = try APOParser.parse(fileURL: dir.appendingPathComponent("main.txt"))
        XCTAssertEqual(r.config.left, [.gain(dB: -2), H.pk(100, 1, 1)])
        XCTAssertEqual(r.config.right, r.config.left)
        XCTAssertEqual(r.warnings.count, 1); XCTAssertTrue(r.warnings[0].contains("missing.txt"))
        // text API with a base directory
        let r2 = APOParser.parse(text: "Include: my file (1).txt", baseURL: sub)
        XCTAssertEqual(r2.config.left.count, 2)
        XCTAssertThrowsError(try APOParser.parse(fileURL: dir.appendingPathComponent("nope.txt")))
    }
}
