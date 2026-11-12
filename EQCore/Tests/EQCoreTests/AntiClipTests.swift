import XCTest
@testable import EQCore

/// Anti-clipping peak search over the full chain (Response.chainPeak / EQProcessor.antiClipGainDB).
final class AntiClipTests: XCTestCase {

    /// Steady-state output peak (dBFS) of a sine of amplitude 1 through a real EQProcessor with anti-clipping on.
    func sinePeakDB(_ cfg: EQConfig, freq: Double, headroom: Double = 0.5, sr: Double = 48000, seconds: Double = 2.5) -> Double {
        let n = Int(sr * seconds)
        let x = (0..<n).map { Float(sin(2 * Double.pi * freq * Double($0) / sr)) }
        let y = H.run(cfg, sr: sr, input: x, blocks: [512], headroom: headroom).left
        return 20 * log10(Double(y[Int(sr * (seconds - 1))...].map { abs($0) }.max()!))
    }

    func gain(_ cfg: EQConfig, headroom: Double? = 0.5, sr: Double = 48000) -> Double {
        EQProcessor(config: cfg, sampleRate: sr, channels: 2, headroomDB: headroom, maxFrames: 512).appliedHeadroomGainDB
    }

    func testHighPassOnlyGivesNoBoost() {
        let hp: [Stage] = [H.hp(30, 0.5412), H.hp(30, 1.3066)]
        let pk = Response.chainPeak(stages: hp, sampleRate: 48000)
        // the Q values are rounded Butterworth values (0.5412, 1.3066): a 7e-6 dB ripple, no real boost
        XCTAssertEqual(pk.dB, 0, accuracy: 1e-4, "a Butterworth high-pass does not boost")
        let cfg = EQConfig(left: hp, right: hp)
        XCTAssertEqual(gain(cfg, headroom: 0), 0, accuracy: 1e-4)
        XCTAssertLessThanOrEqual(gain(cfg, headroom: 0), 0, "never positive")
        XCTAssertEqual(gain(cfg, headroom: 0.5), -0.5, accuracy: 1e-4)
        XCTAssertEqual(gain(EQConfig(left: [H.hp(30, 0.7071)], right: []), headroom: 0), 0, accuracy: 1e-9)
    }

    func testResonantHighPassPeakIsCounted() {
        // 2nd-order high-pass, Q 2: analog resonant peak Q / sqrt(1 - 1/(4 Q^2)) = 6.30 dB at f0 / sqrt(1 - 1/(2 Q^2))
        let q = 2.0
        let expectDB = 20 * log10(q / (1 - 1 / (4 * q * q)).squareRoot())
        let expectF = 100 / (1 - 1 / (2 * q * q)).squareRoot()
        let st: [Stage] = [H.hp(100, q)]
        let pk = Response.chainPeak(stages: st, sampleRate: 48000)
        XCTAssertEqual(pk.dB, expectDB, accuracy: 0.005)
        XCTAssertEqual(pk.freq, expectF, accuracy: 0.5)
        let cfg = EQConfig(left: st, right: st)
        XCTAssertEqual(gain(cfg), -0.5 - expectDB, accuracy: 0.005)
        XCTAssertEqual(Response.peak(stages: st, sampleRate: 48000).dB, 0, accuracy: 1e-9, "reference semantics ignored it")
        XCTAssertEqual(sinePeakDB(cfg, freq: pk.freq), -0.5, accuracy: 0.01)
        // and a resonant low-pass
        let lp: [Stage] = [.biquad(BiquadSpec(kind: .lowPass, freq: 8000, q: 3))]
        XCTAssertEqual(Response.chainPeak(stages: lp, sampleRate: 48000).dB, 20 * log10(3 / (1 - 1 / 36.0).squareRoot()), accuracy: 0.1)
    }

    func testOwnerLikeBoostThenHighPass() {
        // fixture = inline copy of the real config: two cuts, -1 dB preamp, GraphicEQ +11.2 dB at and below 40 Hz,
        // 4th-order Butterworth high-pass at 30 Hz
        let cfg = H.fixtureConfig
        let pk = Response.chainPeak(stages: cfg.left, sampleRate: 48000)
        // independent check 1: the processor's measured impulse response (direct DTFT), finely around the peak
        let h = H.impulse(cfg, length: 48000)   // no anti-clipping gain in the impulse response
        var best = (-1e9, 0.0)
        var f = 37.0
        while f <= 42 { let d = H.dtftDB(h, freq: f, sr: 48000); if d > best.0 { best = (d, f) }; f += 0.05 }
        let applied = gain(cfg)
        XCTAssertEqual(best.0, pk.dB - Response.firMeasurementAllowanceDB, accuracy: 0.005,
                       "peak of the processor's real response")
        XCTAssertEqual(pk.freq, best.1, accuracy: 0.3)
        // independent check 2: ideal curve (exactMagnitudeDB) gives nearly the same peak; the FIR is 0.02 dB higher
        var ideal = -1e9
        f = 30; while f < 60 { ideal = max(ideal, Response.exactMagnitudeDB(stages: cfg.left, freq: f, sampleRate: 48000)); f *= 1.0005 }
        XCTAssertEqual(ideal, 8.88, accuracy: 0.01)
        XCTAssertEqual(pk.dB, 8.91, accuracy: 0.01)
        XCTAssertEqual(applied, -9.41, accuracy: 0.01)
        // empirical: a full-scale sine at the worst-case frequency comes out at or just below -headroom
        let out = sinePeakDB(cfg, freq: pk.freq)
        XCTAssertLessThanOrEqual(out, -0.5)
        XCTAssertGreaterThan(out, -0.53)
        for f in [30.0, 35, 39, 39.5, 40, 41, 45, 50, 1000] { XCTAssertLessThanOrEqual(sinePeakDB(cfg, freq: f), -0.5, "\(f) Hz") }
    }

    func testLeftRightDifferentPeaks() {
        let l: [Stage] = [H.pk(1000, 6, 1)], r: [Stage] = [H.pk(200, 3, 2), .gain(dB: -1)]
        XCTAssertEqual(gain(EQConfig(left: l, right: r)), -6.5, accuracy: 0.005, "the more negative gain wins")
        XCTAssertEqual(gain(EQConfig(left: r, right: l)), -6.5, accuracy: 0.005)
        let pr = Response.chainPeak(stages: r, sampleRate: 48000)
        XCTAssertEqual(pr.dB, 2, accuracy: 0.005); XCTAssertEqual(pr.freq, 200, accuracy: 0.5)
        // mono: only the left chain counts
        let mono = EQProcessor(config: EQConfig(left: r, right: l), sampleRate: 48000, channels: 1, headroomDB: 0.5, maxFrames: 64)
        XCTAssertEqual(mono.appliedHeadroomGainDB, -2.5, accuracy: 0.005)
        XCTAssertEqual(EQProcessor.antiClipGainDB(config: EQConfig(left: r, right: l), sampleRate: 48000, channels: 1, headroomDB: 0.5), -2.5, accuracy: 0.005)
    }

    func testNarrowPeaksAndSampleRateRange() {
        // a Q 30 boost at an odd frequency is found at its exact height
        let narrow: [Stage] = [H.pk(1234.5, 6, 30), H.pk(1300, -3, 1)]
        let exact = Response.exactMagnitudeDB(stages: narrow, freq: 1234.5, sampleRate: 48000)
        XCTAssertGreaterThanOrEqual(Response.chainPeak(stages: narrow, sampleRate: 48000).dB, exact - 1e-6)
        // the search follows the sample rate: a high shelf keeps rising towards Nyquist
        let hs: [Stage] = [.biquad(BiquadSpec(kind: .highShelf, freq: 16000, gainDB: 6, q: 0.7))]
        let p96 = Response.chainPeak(stages: hs, sampleRate: 96000)
        XCTAssertGreaterThan(p96.freq, 22000)
        XCTAssertLessThan(p96.freq, 48000)
        XCTAssertEqual(Response.antiClipSearchRange(sampleRate: 44100).upperBound, 0.999 * 22050, accuracy: 1e-9)
        XCTAssertEqual(Response.antiClipSearchRange(sampleRate: 48000).lowerBound, 1)
    }

    func testMeasuredFIRVersusInterpolatedCurve() {
        // The interpolated (ideal) GraphicEQ curve under-estimates the FIR's real response at steep corners. For the
        // owner-like curves it is within 0.1 dB at 48 kHz; for a narrow low-frequency spike it is off by more than
        // 1 dB on the flanks, which is why the peak search measures the FIR.
        func pts(_ s: String) -> [GraphicEQPoint] {
            if case .graphicEQ(let p) = APOParser.parse(text: s, baseURL: nil).config.left[0] { return p }; return []
        }
        func worstUnder(_ p: [GraphicEQPoint], _ sr: Double) -> Double {
            let k = GraphicEQDesigner.designedKernel(points: p, sampleRate: sr)
            let sorted = p.sorted { $0.freq < $1.freq }
            var w = -1e9
            var f = 1.0
            while f < sr / 2 * 0.99 { w = max(w, k.magnitude.dB(at: f) - GraphicEQDesigner.interpolateDB(sorted, f)); f *= 1.002 }
            for q in sorted { w = max(w, k.magnitude.dB(at: q.freq) - q.gainDB) }
            return w
        }
        let merged = GraphicEQDesigner.merge([pts(H.bass1), pts(H.bass2)])
        XCTAssertLessThan(worstUnder(merged, 48000), 0.1)
        XCTAssertGreaterThan(worstUnder(merged, 48000), 0.01, "the corners do overshoot a little")
        let spike = [GraphicEQPoint(freq: 8.9, gainDB: 0), GraphicEQPoint(freq: 10, gainDB: 12), GraphicEQPoint(freq: 11.2, gainDB: 0)]
        XCTAssertGreaterThan(worstUnder(spike, 48000), 1.0)
        // the measured magnitude equals the processor's impulse response (direct DTFT)
        let cfg = EQConfig(left: [.graphicEQ(points: merged)], right: [.graphicEQ(points: merged)])
        let h = H.impulse(cfg, length: 40000)
        for f in [5.0, 20, 39.5, 45, 50, 80, 100, 1000] {
            XCTAssertEqual(Response.chainMagnitudeDB(stages: cfg.left, freq: f, sampleRate: 48000), H.dtftDB(h, freq: f, sr: 48000),
                           accuracy: 0.005, "\(f) Hz")
        }
    }
}
