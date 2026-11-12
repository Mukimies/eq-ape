import EQCore
import Foundation

/// Frequency-response data for the editor graph, computed from a `WorkspaceEvaluation` with EQCore's exact
/// biquad magnitudes (high/low-pass etc. included) and GraphicEQ's interpolated curve. Cheap enough to recompute
/// on every drag step (a few hundred points).
public struct ResponsePlot: Sendable {
    public struct Options: Equatable, Sendable {
        public var includePreamp = true
        public var includeAntiClip = false
        /// Anti-clipping headroom (dB) as in the device profile; nil = anti-clipping off.
        public var headroomDB: Double? = DeviceProfile.defaultHeadroomDB
        public var sampleRate: Double = 48000
        public init() {}
    }

    public static let minFreq = 20.0, maxFreq = 20000.0

    public var freqs: [Double]
    public var left: [Double]
    public var right: [Double]
    public var channelsDiffer: Bool
    /// Peak of each chain as EQ Ape's anti-clipping computes it (EQCore `Response.peak`, 5 Hz-22 kHz).
    public var peakLeft: (dB: Double, freq: Double)
    public var peakRight: (dB: Double, freq: Double)
    /// Gain the engine applies for anti-clipping with these options' headroom (<= 0; 0 when off).
    public var antiClipDB: Double

    public static func frequencies(count: Int = 400) -> [Double] {
        (0..<count).map { minFreq * pow(maxFreq / minFreq, Double($0) / Double(count - 1)) }
    }

    /// Magnitude (dB) of one stage on the grid; gain stages are flat.
    public static func curve(_ stage: Stage, freqs: [Double], sampleRate: Double) -> [Double] {
        switch stage {
        case .gain(let g): return [Double](repeating: g, count: freqs.count)
        case .biquad(let s):
            guard let c = designBiquad(s, sampleRate: sampleRate) else { return [Double](repeating: 0, count: freqs.count) }
            return freqs.map { c.magnitudeDB(freq: $0, sampleRate: sampleRate) }
        case .graphicEQ(let pts):
            let sorted = pts.sorted { $0.freq < $1.freq }
            return freqs.map { GraphicEQDesigner.interpolateDB(sorted, $0) }
        }
    }

    public static func sum(_ stages: [Stage], freqs: [Double], options: Options) -> [Double] {
        var out = [Double](repeating: 0, count: freqs.count)
        for st in stages {
            if case .gain = st, !options.includePreamp { continue }
            let c = curve(st, freqs: freqs, sampleRate: options.sampleRate)
            for i in out.indices { out[i] += c[i] }
        }
        return out
    }

    /// The engine's anti-clipping gain for a config (same rule as `EQProcessor`).
    public static func antiClipGain(_ config: EQConfig, headroomDB: Double?, sampleRate: Double) -> Double {
        guard let h = headroomDB else { return 0 }
        var need = 0.0
        for chain in [config.left, config.right] {
            need = min(need, -h - Response.peak(stages: chain, sampleRate: sampleRate).dB)
        }
        return need
    }

    /// Grid: `points` log-spaced frequencies plus the centre and band-edge frequencies of every biquad, so narrow
    /// peaks and notches are drawn at their true depth.
    public static func grid(for config: EQConfig, points: Int = 400) -> [Double] {
        var f = frequencies(count: points)
        var extra: [Double] = []
        for st in config.left + config.right {
            guard case .biquad(let b) = st, b.freq > minFreq, b.freq < maxFreq else { continue }
            extra.append(b.freq)
            let q = b.q ?? 1
            let half = 1 / (2 * max(0.05, q))
            for k in [-1.0, -0.5, 0.5, 1.0] { extra.append(b.freq * pow(2, k * half)) }
        }
        if !extra.isEmpty {
            f = Array(Set(f + extra.filter { $0 >= minFreq && $0 <= maxFreq })).sorted()
        }
        return f
    }

    public init(config: EQConfig, options: Options, points: Int = 400) {
        let f = ResponsePlot.grid(for: config, points: points)
        freqs = f
        var l = ResponsePlot.sum(config.left, freqs: f, options: options)
        var r = ResponsePlot.sum(config.right, freqs: f, options: options)
        channelsDiffer = config.left != config.right
        peakLeft = Response.peak(stages: config.left, sampleRate: options.sampleRate)
        peakRight = Response.peak(stages: config.right, sampleRate: options.sampleRate)
        var ac = 0.0
        if let h = options.headroomDB {
            ac = min(0, min(-h - peakLeft.dB, -h - peakRight.dB))
        }
        antiClipDB = ac
        if options.includeAntiClip && ac != 0 {
            for i in l.indices { l[i] += ac }
            for i in r.indices { r[i] += ac }
        }
        left = l; right = r
    }

    /// Value of a curve at an arbitrary frequency (linear interpolation over log f).
    public func value(_ curve: [Double], at freq: Double) -> Double {
        guard curve.count == freqs.count, curve.count > 1 else { return 0 }
        let f = max(freqs[0], min(freqs[freqs.count - 1], freq))
        var lo = 0, hi = freqs.count - 1
        while hi - lo > 1 { let m = (lo + hi) / 2; if freqs[m] <= f { lo = m } else { hi = m } }
        let u = (log(f) - log(freqs[lo])) / max(1e-12, log(freqs[hi]) - log(freqs[lo]))
        return curve[lo] * (1 - u) + curve[hi] * u
    }
}
