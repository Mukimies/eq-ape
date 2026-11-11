import Foundation
import Accelerate
@testable import EQCore

enum H {
    /// Optional real-world Equalizer APO config for the path-based tests (set EQAPE_REAL_CONFIG); tests skip when unset.
    static let realConfigPath = ProcessInfo.processInfo.environment["EQAPE_REAL_CONFIG"] ?? ""

    /// Run a mono signal (same on both channels) through a real EQProcessor with the given block sizes.
    static func run(_ cfg: EQConfig, sr: Double = 48000, input: [Float], blocks: [Int], headroom: Double? = nil,
                    maxFrames: Int = 1024) -> (left: [Float], right: [Float], proc: EQProcessor) {
        let proc = EQProcessor(config: cfg, sampleRate: sr, channels: 2, headroomDB: headroom, maxFrames: maxFrames)
        var l = input, r = input
        var pos = 0, bi = 0
        l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in
                let ptrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)
                defer { ptrs.deallocate() }
                while pos < input.count {
                    let n = min(blocks[bi % blocks.count], input.count - pos)
                    bi += 1
                    ptrs[0] = lp.baseAddress! + pos; ptrs[1] = rp.baseAddress! + pos
                    proc.process(UnsafePointer(ptrs), frames: n)
                    pos += n
                }
            }
        }
        return (l, r, proc)
    }

    static func impulse(_ cfg: EQConfig, length: Int, sr: Double = 48000) -> [Float] {
        var x = [Float](repeating: 0, count: length); x[0] = 1
        return run(cfg, sr: sr, input: x, blocks: [512]).left
    }

    /// Direct DTFT magnitude in dB (exact evaluation of the measured impulse response).
    static func dtftDB(_ h: [Float], freq: Double, sr: Double) -> Double {
        var re = 0.0, im = 0.0
        let w = 2 * Double.pi * freq / sr
        for (n, v) in h.enumerated() {
            re += Double(v) * cos(w * Double(n)); im -= Double(v) * sin(w * Double(n))
        }
        return 20 * log10(hypot(re, im))
    }

    static func directConv(_ x: [Double], _ h: [Double]) -> [Double] {
        let T = h.count
        let padded = [Double](repeating: 0, count: T - 1) + x
        let hr = Array(h.reversed())
        var out = [Double](repeating: 0, count: x.count)
        vDSP_convD(padded, 1, hr, 1, &out, 1, vDSP_Length(x.count), vDSP_Length(T))
        return out
    }

    static func realFiles() -> URL? {
        FileManager.default.fileExists(atPath: realConfigPath) ? URL(fileURLWithPath: realConfigPath) : nil
    }

    static func pk(_ f: Double, _ g: Double, _ q: Double) -> Stage { .biquad(BiquadSpec(kind: .peaking, freq: f, gainDB: g, q: q)) }
    static func hp(_ f: Double, _ q: Double) -> Stage { .biquad(BiquadSpec(kind: .highPass, freq: f, q: q)) }

    static let bass1 = "GraphicEQ: 20 6.2; 25 6.2; 31.5 6.2; 40 6.2; 50 0; 63 0; 80 0; 100 0; 125 0; 160 0; 200 0; 250 0; 315 0; 400 0; 500 0; 630 0; 800 0; 1000 0; 1250 0; 1600 0; 2000 0; 2500 0; 3150 0; 4000 0; 5000 0; 6300 0; 8000 0; 10000 0; 12500 0; 16000 0; 20000 0"
    static let bass2 = "GraphicEQ: 20 5; 25 5; 31.5 5; 40 5; 50 5; 63 5; 80 5; 100 0; 125 0; 160 0; 200 0; 250 0; 315 0; 400 0; 500 0; 630 0; 800 0; 1000 0; 1250 0; 1600 0; 2000 0; 2500 0; 3150 0; 4000 0; 5000 0; 6300 0; 8000 0; 10000 0; 12500 0; 16000 0; 20000 0"

    /// Inline copy of the real config (REW header, comments, Preamp, HPQ pair, two GraphicEQ).
    static var fixtureText: String {
        """
        Filter Settings file

        Room EQ V5.31.3
        Dated: 29.11.2024 12:58:32

        Notes:

        Equaliser: Generic
        L+R base
        Filter: ON PK Fc 60.8 Hz Gain -8.5 dB Q 3.634
        Filter  2: ON  PK       Fc   118.0 Hz  Gain -14.80 dB  Q 10.339
        # Filter: ON PK Fc 167.5 Hz Gain -8.6 dB Q 1.137
        Filter  1: ON  None
        Filter  2: ON  None
        Preamp: -1 dB
        \(bass1)
        \(bass2)
        # 4th-order Butterworth
        Filter 1: ON HPQ Fc 30 Hz Q 0.5412
        Filter 2: ON HPQ Fc 30 Hz Q 1.3066
        """
    }

    static var fixtureConfig: EQConfig { APOParser.parse(text: fixtureText, baseURL: nil).config }
}
