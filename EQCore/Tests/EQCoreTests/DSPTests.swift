import XCTest
import Accelerate
@testable import EQCore

final class DSPTests: XCTestCase {

    func testLowShelfResponse() {
        let st: [Stage] = [.biquad(BiquadSpec(kind: .lowShelf, freq: 78, gainDB: 7.2, q: 0.8))]
        for (f, e) in [(20.0, 7.27), (50, 6.53), (70, 4.51), (100, 1.66), (150, 0.16)] {
            XCTAssertEqual(Response.magnitudeDB(stages: st, freq: f, sampleRate: 48000), e, accuracy: 0.02, "\(f) Hz")
        }
    }

    func testShelfSlopeEqualsQ() {
        // slope 12 dB/oct <=> S = 1 <=> Q = 1/sqrt(2)
        let a = designBiquad(BiquadSpec(kind: .highShelf, freq: 5000, gainDB: 6, slopeDBPerOct: 12), sampleRate: 48000)!
        let b = designBiquad(BiquadSpec(kind: .highShelf, freq: 5000, gainDB: 6, q: 1 / 2.0.squareRoot()), sampleRate: 48000)!
        XCTAssertEqual(a.b0, b.b0, accuracy: 1e-9); XCTAssertEqual(a.a2, b.a2, accuracy: 1e-9)
    }

    func testCascadedHighPassThroughProcessor() {
        let cfg = EQConfig(left: [H.hp(30, 0.5412), H.hp(30, 1.3066)], right: [H.hp(30, 0.5412), H.hp(30, 1.3066)])
        let h = H.impulse(cfg, length: 48000)
        for (f, e) in [(20.0, -14.25), (30, -3.01), (40, -0.41)] {
            XCTAssertEqual(H.dtftDB(h, freq: f, sr: 48000), e, accuracy: 0.05, "\(f) Hz")
        }
        // and with an actual sine
        var x = [Float](repeating: 0, count: 96000)
        for i in 0..<x.count { x[i] = Float(0.5 * sin(2 * Double.pi * 30 * Double(i) / 48000)) }
        let y = H.run(cfg, input: x, blocks: [480]).left
        let peak = y[48000...].map { abs($0) }.max()!
        XCTAssertEqual(20 * log10(Double(peak) / 0.5), -3.01, accuracy: 0.05)
    }

    func testRealGraphicEQCurves() {
        let r = APOParser.parse(text: H.bass1 + "\n" + H.bass2, baseURL: nil)
        XCTAssertEqual(r.config.left.count, 2)
        let h = H.impulse(r.config, length: 40000)
        for (f, e) in [(20.0, 11.2), (30, 11.2), (40, 11.14), (63, 5.0), (125, 0.0), (1000, 0.0)] {
            XCTAssertEqual(H.dtftDB(h, freq: f, sr: 48000), e, accuracy: 0.1, "\(f) Hz")
        }
        let maxIdx = h.indices.max { abs(h[$0]) < abs(h[$1]) }!
        XCTAssertEqual(maxIdx, 0)
    }

    func testFIRMatchesDirectConvolutionWithMixedBlocks() {
        let pts = APOParser.parse(text: H.bass1, baseURL: nil).config.left
        guard case .graphicEQ(let p) = pts[0] else { return XCTFail() }
        let fir = GraphicEQDesigner.design(points: p, sampleRate: 48000)
        XCTAssertEqual(fir.count, 32768)
        var rng = SystemRandomNumberGenerator()
        let n = 20000
        let x: [Float] = (0..<n).map { _ in Float.random(in: -0.5...0.5, using: &rng) }
        let expect = H.directConv(x.map(Double.init), fir)
        for blocks in [[1, 7, 64, 480, 512, 1024], [512], [1], [1024, 3, 255, 256, 257]] {
            let y = H.run(EQConfig(left: pts, right: pts), input: x, blocks: blocks).left
            var maxErr = 0.0
            for i in 0..<n { maxErr = max(maxErr, abs(Double(y[i]) - expect[i])) }
            XCTAssertLessThan(maxErr, 1e-4, "blocks \(blocks)")
        }
    }

    func testMixedChainEqualsSumOfParts() {
        // biquads + gain + merged FIR through the processor vs separate runs
        let cfg = H.fixtureConfig
        let h = H.impulse(cfg, length: 60000)
        let st = cfg.left
        let exact = Response.exactMagnitudeDB(stages: st, freq: 100, sampleRate: 48000)
        XCTAssertEqual(H.dtftDB(h, freq: 100, sr: 48000), exact, accuracy: 0.1)
        let exact2 = Response.exactMagnitudeDB(stages: st, freq: 2000, sampleRate: 48000)
        XCTAssertEqual(H.dtftDB(h, freq: 2000, sr: 48000), exact2, accuracy: 0.05)
    }

    func testPeakAndHeadroom() throws {
        var cfg = H.fixtureConfig
        if let url = H.realFiles() { cfg = try APOParser.parse(fileURL: url).config }
        // The early reference semantics (high-pass ignored) are kept in `Response.peak` for compatibility: +10.19 dB
        // at 5 Hz, below the 30 Hz high-pass. Anti-clipping no longer uses them (see AntiClipTests).
        let ref = Response.peak(stages: cfg.left, sampleRate: 48000)
        XCTAssertEqual(ref.dB, 10.19, accuracy: 0.05)
        let pk = Response.chainPeak(stages: cfg.left, sampleRate: 48000)
        XCTAssertEqual(pk.dB, 8.91, accuracy: 0.02)
        XCTAssertEqual(pk.freq, 39.5, accuracy: 0.5)
        let p = EQProcessor(config: cfg, sampleRate: 48000, channels: 2, headroomDB: 0.5, maxFrames: 512)
        XCTAssertEqual(p.appliedHeadroomGainDB, -9.41, accuracy: 0.02)   // was -10.69 with the reference peak
        XCTAssertEqual(p.appliedHeadroomGainDB, -0.5 - pk.dB, accuracy: 1e-9)
        let q = EQProcessor(config: cfg, sampleRate: 48000, channels: 2, headroomDB: -20, maxFrames: 512)
        XCTAssertEqual(q.appliedHeadroomGainDB, 0)
        let r = EQProcessor(config: cfg, sampleRate: 48000, channels: 2, headroomDB: nil, maxFrames: 512)
        XCTAssertEqual(r.appliedHeadroomGainDB, 0)
    }

    func testPeakAndClipCounters() {
        let cfg = EQConfig(left: [.gain(dB: 6.0206)], right: [.gain(dB: 6.0206)])   // x2
        var x = [Float](repeating: 0.1, count: 100); x[10] = 0.6; x[20] = -0.7; x[30] = 0.45
        let r = H.run(cfg, input: x, blocks: [100])
        XCTAssertEqual(r.proc.clippedSamples, 2 * 2)   // two channels, samples 10 and 20 (1.2, -1.4); 0.5*2 ~ 1.0 counts only if >= 1
        let pk = r.proc.peakLinear
        XCTAssertEqual(pk[0], 1.4, accuracy: 0.01)
        XCTAssertEqual(r.proc.peakLinear, [0, 0])
        XCTAssertEqual(r.left[10], 1.2, accuracy: 0.001)   // not clamped
    }

    func testLeftRightDiffer() {
        let cfg = EQConfig(left: [.gain(dB: -6.0206)], right: [])
        let x = [Float](repeating: 1, count: 64)
        let r = H.run(cfg, input: x, blocks: [64])
        XCTAssertEqual(r.left[5], 0.5, accuracy: 1e-3); XCTAssertEqual(r.right[5], 1, accuracy: 1e-6)
    }

    func testPerformance() {
        var cfg = H.fixtureConfig
        if let url = H.realFiles(), let r = try? APOParser.parse(fileURL: url) { cfg = r.config }
        let proc = EQProcessor(config: cfg, sampleRate: 48000, channels: 2, headroomDB: 0.5, maxFrames: 512)
        let frames = 512, blocksCount = 48000 * 10 / 512
        let l = UnsafeMutablePointer<Float>.allocate(capacity: frames), r = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let ptrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)
        defer { l.deallocate(); r.deallocate(); ptrs.deallocate() }
        ptrs[0] = l; ptrs[1] = r
        let src = (0..<frames).map { Float(0.1 * sin(Double($0) * 0.05)) }
        let t0 = clock()
        let w0 = Date()
        for _ in 0..<blocksCount {
            l.update(from: src, count: frames); r.update(from: src, count: frames)
            proc.process(UnsafePointer(ptrs), frames: frames)
        }
        let cpu = Double(clock() - t0) / Double(CLOCKS_PER_SEC)
        let wall = Date().timeIntervalSince(w0)
        print("PERF: 10 s stereo 48 kHz, 512-frame blocks: cpu \(String(format: "%.3f", cpu)) s, wall \(String(format: "%.3f", wall)) s")
        XCTAssertLessThan(cpu, 1.0)
    }
}
