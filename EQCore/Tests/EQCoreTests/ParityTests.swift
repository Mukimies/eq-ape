import XCTest
@testable import EQCore

/// Expected values are derived from Equalizer APO's behaviour (BiQuad.cpp, BiQuadFilterFactory.cpp,
/// BiQuadFilter.cpp, GraphicEQFilterFactory.cpp, PreampFilterFactory.cpp, ChannelFilter.cpp,
/// IncludeFilterFactory.cpp, FilterEngine.cpp), re-derived here independently.
final class ParityTests: XCTestCase {
    func p(_ s: String) -> ParseResult { APOParser.parse(text: s, baseURL: nil) }
    func one(_ s: String) -> BiquadSpec? {
        if case .biquad(let b)? = p(s).config.left.first { return b }
        return nil
    }

    func testBandwidthFormula() throws {
        // alpha = sin(w) * sinh(ln2/2 * BW * w / sin(w)); PK: b0 = (1+alpha*A)/(1+alpha/A), a2 = (1-alpha/A)/(1+alpha/A)
        let spec = try XCTUnwrap(one("Filter: ON PEQ Fc 1000 Hz Gain 6 dB BW Oct 0.5"))
        let c = try XCTUnwrap(designBiquad(spec, sampleRate: 48000))
        let w = 2 * Double.pi * 1000 / 48000, A = pow(10, 6.0 / 40)
        let al = sin(w) * sinh(log(2.0) / 2 * 0.5 * w / sin(w))
        XCTAssertEqual(c.b0, (1 + al * A) / (1 + al / A), accuracy: 1e-12)
        XCTAssertEqual(c.a2, (1 - al / A) / (1 + al / A), accuracy: 1e-12)
        // BW overrides a Q on the same line (regexBW is applied after regexQ)
        let both = try XCTUnwrap(one("Filter: ON PK Fc 1000 Hz Gain 6 dB Q 5 BW Oct 0.5"))
        XCTAssertEqual(both.bandwidthOct, 0.5); XCTAssertNil(both.q)
        // "BW" without "Oct" is not recognised, so PK has neither Q nor BW -> not converted
        XCTAssertNil(one("Filter: ON PK Fc 1000 Hz Gain 6 dB BW 0.5"))
    }

    func testDefaultShelfSlopeIsS09() throws {
        // BiQuadFilterFactory: default bandwidthOrQOrS = 0.9 as S. alpha = sn/2*sqrt((A+1/A)(1/S-1)+2)
        let s = try XCTUnwrap(one("Filter: ON LS Fc 100 Hz Gain 6 dB"))
        XCTAssertEqual(s.slopeDBPerOct, 10.8); XCTAssertEqual(s.freq, 100)   // default form: no corner shift
        let c = try XCTUnwrap(designBiquad(s, sampleRate: 48000))
        let w = 2 * Double.pi * 100 / 48000, A = pow(10, 6.0 / 40)
        let al = sin(w) / 2 * ((A + 1 / A) * (1 / 0.9 - 1) + 2).squareRoot()
        let beta = 2 * A.squareRoot() * al, cs = cos(w)
        let b0 = A * ((A + 1) - (A - 1) * cs + beta), a0 = (A + 1) + (A - 1) * cs + beta
        XCTAssertEqual(c.b0, b0 / a0, accuracy: 1e-12)
    }

    func testShelfCornerFrequencyConversion() throws {
        // BiQuadFilter::initialize: centre = fc * 10^(|gain|/80/S) (LS), fc / ... (HS); S = slope/12
        let ls = try XCTUnwrap(one("Filter: ON LS 12 dB Fc 100 Hz Gain 6 dB"))
        XCTAssertEqual(ls.freq, 100 * pow(10, 6.0 / 80), accuracy: 1e-9); XCTAssertEqual(ls.slopeDBPerOct, 12)
        let hs = try XCTUnwrap(one("Filter: ON HS 6dB Fc 1000 Hz Gain -6 dB"))   // S = 0.5
        XCTAssertEqual(hs.freq, 1000 / pow(10, 6.0 / 80 / 0.5), accuracy: 1e-9)
        // with Q: S = 1/((1/q^2 - 2)/(A+1/A) + 1), A = 10^(gain/40)
        let lq = try XCTUnwrap(one("Filter: ON LS Fc 100 Hz Gain 6 dB Q 0.5"))
        let A = pow(10, 6.0 / 40), S = 1 / ((1 / 0.25 - 2) / (A + 1 / A) + 1)
        XCTAssertEqual(lq.freq, 100 * pow(10, 6.0 / 80 / S), accuracy: 1e-9); XCTAssertEqual(lq.q, 0.5)
        // C variants are centre frequencies: unchanged
        XCTAssertEqual(try XCTUnwrap(one("Filter: ON LSC 12 dB Fc 100 Hz Gain 6 dB")).freq, 100)
        XCTAssertEqual(try XCTUnwrap(one("Filter: ON HSC Fc 100 Hz Gain 6 dB Q 0.5")).freq, 100)
        // BW is ignored for shelves; a slope beats a Q
        XCTAssertEqual(try XCTUnwrap(one("Filter: ON LSC Fc 100 Hz Gain 3 dB BW Oct 1")).slopeDBPerOct, 10.8)
        let both = try XCTUnwrap(one("Filter: ON LSC 6 dB Fc 100 Hz Gain 3 dB Q 2"))
        XCTAssertEqual(both.slopeDBPerOct, 6); XCTAssertNil(both.q)
    }

    func testRequiredParametersSkipFilter() {
        XCTAssertNil(one("Filter: ON PK Fc 100 Hz Gain 3 dB"))          // no Q/BW: error in APO
        XCTAssertNil(one("Filter: ON AP Fc 100 Hz"))                    // AP requires Q
        XCTAssertNil(one("Filter: ON PK Fc 100 Hz Q 2"))                // gain required
        XCTAssertNil(one("Filter: ON LS Fc 100 Hz"))                    // gain required
        XCTAssertNotNil(one("Filter: ON HP Fc 100 Hz Gain 3 dB"))       // gain ignored for HP
        XCTAssertEqual(p("Filter: ON PK Fc 100 Hz Gain 3 dB").warnings.count, 1)
    }

    func testCaseSensitivity() {
        XCTAssertTrue(p("preamp: -3 dB").config.left.isEmpty)
        XCTAssertEqual(p("preamp: -3 dB").warnings.count, 1)
        XCTAssertTrue(p("Filter: ON pk Fc 100 Hz Gain 3 dB Q 1").config.left.isEmpty)
        XCTAssertTrue(p("Filter: on PK Fc 100 Hz Gain 3 dB Q 1").config.left.isEmpty)
        XCTAssertTrue(p("Filter: ON PK fc 100 hz Gain 3 dB Q 1").config.left.isEmpty)
        XCTAssertNotNil(one("Filter: ON Modal Fc 100 Hz Gain 3 dB Q 1"))
        XCTAssertTrue(p("Filter: ON MODAL Fc 100 Hz Gain 3 dB Q 1").config.left.isEmpty)
        // Channel words are upper-cased by APO, so these are accepted
        XCTAssertEqual(p("Channel: l\nPreamp: -1 dB").config.right.count, 0)
        XCTAssertEqual(p("Channel: all\nPreamp: -1 dB").config.right.count, 1)
    }

    func testPreampNumberOnly() {
        // sscanf(" %lf dB") returns 1 after the number even if "dB" does not follow
        XCTAssertEqual(p("Preamp: -6 db").config.left, [.gain(dB: -6)])
        XCTAssertEqual(p("Preamp: -6").config.left, [.gain(dB: -6)])
        XCTAssertEqual(p("Preamp: .5 dB").config.left, [.gain(dB: 0.5)])
        XCTAssertEqual(p("Preamp: +1,5 dB").config.left, [.gain(dB: 1.5)])
        XCTAssertTrue(p("Preamp: loud dB").config.left.isEmpty)
    }

    func testFrequencyThousandsQuirk() throws {
        // getFreq: length >= 5, no e/E, '.' at 4th-last position -> thousands separator
        XCTAssertEqual(try XCTUnwrap(one("Filter: ON PK Fc 1.000 Hz Gain 3 dB Q 1")).freq, 1000)
        XCTAssertEqual(try XCTUnwrap(one("Filter: ON PK Fc 2,500 Hz Gain 3 dB Q 1")).freq, 2500)
        XCTAssertEqual(try XCTUnwrap(one("Filter: ON PK Fc 118.0 Hz Gain 3 dB Q 1")).freq, 118)
        XCTAssertEqual(try XCTUnwrap(one("Filter: ON PK Fc 60.8 Hz Gain 3 dB Q 1")).freq, 60.8)
        XCTAssertEqual(try XCTUnwrap(one("Filter: ON PK Fc 1e3 Hz Gain 3 dB Q 1")).freq, 1000)
        XCTAssertEqual(try XCTUnwrap(one("Filter: ON PK Fc 1000 Hz Gain 3 dB Q 1")).freq, 1000)
    }

    func testGraphicEQTokenisation() {
        let want: [Stage] = [.graphicEQ(points: [GraphicEQPoint(freq: 20, gainDB: 1), GraphicEQPoint(freq: 30, gainDB: 2),
                                                 GraphicEQPoint(freq: 40, gainDB: 3)])]
        XCTAssertEqual(p("GraphicEQ:20 1;30 2 ;  40\t3;").config.left, want)
        XCTAssertEqual(p("GraphicEQ: 20 1 30 2 40 3").config.left, want)          // separators are optional
        XCTAssertEqual(p("GraphicEQ: 40 3; 20 1; 30 2").config.left, want)        // sorted
        XCTAssertEqual(p("GraphicEQ: 20 1,5; 30 2").config.left,
                       [.graphicEQ(points: [GraphicEQPoint(freq: 20, gainDB: 1.5), GraphicEQPoint(freq: 30, gainDB: 2)])])
    }

    func testChannelRestoredAfterInclude() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eqcore-par-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "Channel: R\nPreamp: -4 dB\n".write(to: dir.appendingPathComponent("inc.txt"), atomically: true, encoding: .utf8)
        try "Include: inc.txt\nPreamp: -1 dB\nChannel: L\nInclude: inc.txt\nPreamp: -2 dB\n"
            .write(to: dir.appendingPathComponent("main.txt"), atomically: true, encoding: .utf8)
        let r = try APOParser.parse(fileURL: dir.appendingPathComponent("main.txt"))
        // FilterEngine::loadConfigFile restores currentChannelNames when a file ends
        XCTAssertEqual(r.config.left, [.gain(dB: -1), .gain(dB: -2)])
        XCTAssertEqual(r.config.right, [.gain(dB: -4), .gain(dB: -1), .gain(dB: -4)])
    }

    func testNumericChannels() {
        let r = p("Channel: 1\nPreamp: -1 dB\nChannel: 2\nPreamp: -2 dB\nChannel: 1 2\nPreamp: -3 dB")
        XCTAssertEqual(r.config.left, [.gain(dB: -1), .gain(dB: -3)])
        XCTAssertEqual(r.config.right, [.gain(dB: -2), .gain(dB: -3)])
    }
}
