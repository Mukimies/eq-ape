import Foundation
import Accelerate

// Anti-clipping peak search over the full chain (every biquad kind, gains and the designed GraphicEQ FIR).
//
// The search evaluates the exact magnitude of every stage: biquads with `BiquadCoeffs.magnitudeDB` (high-pass,
// low-pass, notch, all-pass and band-pass included, so a high-pass removes the bass below it and a high-Q
// high-pass/low-pass contributes its resonant peak), and GraphicEQ with the measured magnitude of the FIR the
// processor actually runs (not the ideal interpolated curve, which the FIR follows only approximately at steep
// corners and at very low frequencies; see docs/EQCORE-NOTES.md, "Anti-clipping").

/// Magnitude response of a designed FIR, sampled on a fine FFT grid (bin spacing fs / fftSize) and read with
/// linear interpolation in dB between bins.
public struct FIRMagnitude: Sendable {
    public let sampleRate: Double
    public let binHz: Double
    /// dB per bin, 0...fftSize/2.
    public let db: [Float]

    /// FFT of `taps` zero-padded to `fftSize` (a power of two, at least taps.count; default 8x the length).
    public init(taps: [Double], sampleRate: Double, fftSize: Int? = nil) {
        var n = 1
        let want = max(fftSize ?? taps.count * 8, taps.count, 16)
        while n < want { n <<= 1 }
        var log2n = 0; while (1 << log2n) < n { log2n += 1 }
        self.sampleRate = sampleRate
        binHz = sampleRate / Double(n)
        var re = [Double](repeating: 0, count: n)
        var im = [Double](repeating: 0, count: n)
        for i in 0..<taps.count { re[i] = taps[i] }
        if let setup = vDSP_create_fftsetupD(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) {
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var sc = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zipD(setup, &sc, 1, vDSP_Length(log2n), FFTDirection(kFFTDirection_Forward))
                }
            }
            vDSP_destroy_fftsetupD(setup)
        }
        var out = [Float](repeating: 0, count: n / 2 + 1)
        for k in 0...(n / 2) { out[k] = Float(10 * log10(max(re[k] * re[k] + im[k] * im[k], 1e-300))) }
        db = out
    }

    /// Magnitude in dB at `freq` (clamped to 0...Nyquist).
    public func dB(at freq: Double) -> Double {
        let x = max(0, min(Double(db.count - 1), freq / binHz))
        let i = Int(x)
        if i >= db.count - 1 { return Double(db[db.count - 1]) }
        let u = x - Double(i)
        return Double(db[i]) * (1 - u) + Double(db[i + 1]) * u
    }
}

extension GraphicEQDesigner {
    /// A designed kernel and its measured magnitude.
    public struct DesignedKernel: Sendable {
        public let points: [GraphicEQPoint]
        public let sampleRate: Double
        public let taps: [Double]
        public let magnitude: FIRMagnitude
    }

    private final class KernelCache: @unchecked Sendable {
        let lock = NSLock()
        var entries: [DesignedKernel] = []
        let capacity = 8
    }
    private static let cache = KernelCache()

    /// `design(points:sampleRate:)` plus the measured magnitude, memoised (the last 8 curves). `EQProcessor` and the
    /// anti-clipping peak search use this, so the peak search measures exactly the kernel the processor runs.
    public static func designedKernel(points: [GraphicEQPoint], sampleRate: Double) -> DesignedKernel {
        let c = cache
        c.lock.lock()
        if let i = c.entries.firstIndex(where: { $0.points == points && $0.sampleRate == sampleRate }) {
            let k = c.entries.remove(at: i)
            c.entries.append(k)
            c.lock.unlock()
            return k
        }
        c.lock.unlock()
        let taps = design(points: points, sampleRate: sampleRate)
        let k = DesignedKernel(points: points, sampleRate: sampleRate, taps: taps,
                               magnitude: FIRMagnitude(taps: taps, sampleRate: sampleRate))
        c.lock.lock()
        c.entries.append(k)
        if c.entries.count > c.capacity { c.entries.removeFirst(c.entries.count - c.capacity) }
        c.lock.unlock()
        return k
    }

    /// The merged curve of a chain's GraphicEQ stages, or nil when there is none or it is flat (the processor then
    /// runs no FIR at all).
    public static func mergedCurve(of stages: [Stage]) -> [GraphicEQPoint]? {
        var curves: [[GraphicEQPoint]] = []
        for st in stages { if case .graphicEQ(let p) = st, !p.isEmpty { curves.append(p) } }
        if curves.isEmpty { return nil }
        let merged = merge(curves)
        return merged.contains(where: { abs($0.gainDB) > 1e-9 }) ? merged : nil
    }
}

extension Response {
    /// Frequency range of the anti-clipping peak search: 1 Hz up to just below Nyquist (0.999 * fs/2), so it follows
    /// the sample rate (at 96 kHz content up to 48 kHz is boosted too).
    public static func antiClipSearchRange(sampleRate fs: Double) -> ClosedRange<Double> {
        1.0...max(2.0, 0.999 * fs / 2)
    }

    /// Exact magnitude (dB) of the full chain as the processor runs it: gains, every biquad kind, and the merged
    /// GraphicEQ FIR's measured response.
    public static func chainMagnitudeDB(stages: [Stage], freq: Double, sampleRate: Double) -> Double {
        ChainEvaluator(stages: stages, sampleRate: sampleRate).eval(freq)
    }

    struct ChainEvaluator {
        var gainDB = 0.0
        var biquads: [(spec: BiquadSpec, c: BiquadCoeffs)] = []
        var fir: GraphicEQDesigner.DesignedKernel?
        let fs: Double

        init(stages: [Stage], sampleRate: Double) {
            fs = sampleRate
            for st in stages {
                switch st {
                case .gain(let g): gainDB += g
                case .biquad(let s): if let c = designBiquad(s, sampleRate: sampleRate) { biquads.append((s, c)) }
                case .graphicEQ: break
                }
            }
            if let merged = GraphicEQDesigner.mergedCurve(of: stages) {
                fir = GraphicEQDesigner.designedKernel(points: merged, sampleRate: sampleRate)
            }
        }

        func eval(_ f: Double) -> Double {
            var t = gainDB
            for b in biquads { t += b.c.magnitudeDB(freq: f, sampleRate: fs) }
            if let k = fir { t += k.magnitude.dB(at: f) }
            return t
        }
    }

    /// Allowance added to `chainPeak` when the chain runs a GraphicEQ FIR: the FIR's magnitude is measured on FFT
    /// bins (fs / 262144 apart) and interpolated linearly in dB between them, and the processor convolves in Float32.
    /// Sine sweeps through `EQProcessor` matched the measured response within 0.0015 dB (docs/EQCORE-NOTES.md).
    public static let firMeasurementAllowanceDB = 0.01

    /// Peak of the full chain (see `chainMagnitudeDB`): the value EQ Ape's anti-clipping uses. When the chain has a
    /// GraphicEQ FIR, `dB` includes `firMeasurementAllowanceDB`; biquad-only chains are exact.
    ///
    /// Search grid: 4000 log-spaced points over `antiClipSearchRange`, plus, for every biquad, its centre/corner
    /// frequency and points 1/96 octave apart within ±1/2 octave of it (narrow peaks and the resonant peak of a
    /// high-Q high-pass or low-pass lie there), plus every GraphicEQ node and its 1/96-octave neighbours. The best
    /// local maxima are then refined by golden-section search in log frequency.
    public static func chainPeak(stages: [Stage], sampleRate fs: Double) -> (dB: Double, freq: Double) {
        let ev = ChainEvaluator(stages: stages, sampleRate: fs)
        let range = antiClipSearchRange(sampleRate: fs)
        let lo = range.lowerBound, hi = range.upperBound
        var grid: [Double] = []
        let n = 4000
        grid.reserveCapacity(n + 64 * ev.biquads.count)
        for i in 0..<n { grid.append(lo * pow(hi / lo, Double(i) / Double(n - 1))) }
        for b in ev.biquads {
            for k in -48...48 { grid.append(b.spec.freq * pow(2, Double(k) / 96)) }
        }
        for st in stages {
            if case .graphicEQ(let p) = st {
                for q in p where q.freq > 0 { for k in -2...2 { grid.append(q.freq * pow(2, Double(k) / 96)) } }
            }
        }
        grid = Array(Set(grid.filter { $0 >= lo && $0 <= hi })).sorted()
        let vals = grid.map { ev.eval($0) }
        guard !vals.isEmpty else { return (ev.gainDB, lo) }

        // local maxima (plateaus count once), best first
        var maxima: [Int] = []
        for i in vals.indices {
            let l = i > 0 ? vals[i - 1] : -Double.infinity
            let r = i + 1 < vals.count ? vals[i + 1] : -Double.infinity
            if vals[i] >= l && vals[i] >= r { maxima.append(i) }
        }
        if maxima.isEmpty { maxima = [vals.indices.max { vals[$0] < vals[$1] }!] }
        maxima.sort { vals[$0] > vals[$1] }

        var best = (dB: vals[maxima[0]], freq: grid[maxima[0]])
        for i in maxima.prefix(8) {
            // golden-section search on log f between the neighbours
            var a = log(grid[max(0, i - 1)]), b = log(grid[min(grid.count - 1, i + 1)])
            let g = (5.0.squareRoot() - 1) / 2
            var c = b - g * (b - a), d = a + g * (b - a)
            var fc = ev.eval(exp(c)), fd = ev.eval(exp(d))
            for _ in 0..<40 {
                if fc > fd { b = d; d = c; fd = fc; c = b - g * (b - a); fc = ev.eval(exp(c)) }
                else { a = c; c = d; fc = fd; d = a + g * (b - a); fd = ev.eval(exp(d)) }
            }
            let cands = [(vals[i], grid[i]), (fc, exp(c)), (fd, exp(d))]
            for (v, f) in cands where v > best.dB { best = (v, f) }
        }
        if ev.fir != nil { best.dB += firMeasurementAllowanceDB }
        return best
    }
}

extension EQProcessor {
    /// The anti-clipping gain (dB, <= 0) `EQProcessor` applies: `min(0, -headroomDB - peak)` per chain with
    /// `Response.chainPeak`, the more negative of left and right (only left for one channel). 0 when `headroomDB`
    /// is nil. The editor and the headless status use this same function.
    public static func antiClipGainDB(config: EQConfig, sampleRate: Double, channels: Int = 2, headroomDB: Double?) -> Double {
        guard let h = headroomDB else { return 0 }
        var need = 0.0
        let chains = channels <= 1 ? [config.left] : [config.left, config.right]
        for chain in chains { need = min(need, -h - Response.chainPeak(stages: chain, sampleRate: sampleRate).dB) }
        return need
    }
}
