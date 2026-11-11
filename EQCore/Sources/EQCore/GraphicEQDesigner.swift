import Foundation
import Accelerate

/// Minimum-phase FIR design for GraphicEQ curves (homomorphic / cepstral method, as `write_fir`).
public enum GraphicEQDesigner {
    public static let defaultTaps = 32768

    /// Gain at `f`: linear in dB over log-frequency, held flat outside the end points. `points` must be sorted.
    public static func interpolateDB(_ points: [GraphicEQPoint], _ f: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if f <= first.freq { return first.gainDB }
        if f >= last.freq { return last.gainDB }
        for i in 1..<points.count {
            let p0 = points[i - 1], p1 = points[i]
            if p0.freq <= f && f <= p1.freq {
                if p1.freq <= p0.freq { return p1.gainDB }
                let t = (log(f) - log(p0.freq)) / (log(p1.freq) - log(p0.freq))
                return p0.gainDB + t * (p1.gainDB - p0.gainDB)
            }
        }
        return last.gainDB
    }

    /// Sum several curves (in dB) into one; exact because each curve is piecewise linear in log f
    /// (flat extension included), so the sum has breakpoints only at the union of the inputs' breakpoints.
    public static func merge(_ curves: [[GraphicEQPoint]]) -> [GraphicEQPoint] {
        let sortedCurves = curves.map { $0.sorted { $0.freq < $1.freq } }
        if sortedCurves.count == 1 { return sortedCurves[0] }
        var freqs = Set<Double>()
        for c in sortedCurves { for p in c { freqs.insert(p.freq) } }
        return freqs.sorted().map { f in
            GraphicEQPoint(freq: f, gainDB: sortedCurves.reduce(0) { $0 + interpolateDB($1, f) })
        }
    }

    /// Design a minimum-phase FIR of `taps` samples (FFT size 8x taps, cosine fade over the last eighth).
    public static func design(points: [GraphicEQPoint], sampleRate fs: Double, taps: Int = defaultTaps) -> [Double] {
        precondition(taps >= 16)
        var n = 1; while n < taps * 8 { n <<= 1 }
        var log2n = 0; while (1 << log2n) < n { log2n += 1 }
        let half = n / 2

        // unique ascending points in log-frequency
        var px: [Double] = [], py: [Double] = []
        for p in points.sorted(by: { $0.freq < $1.freq }) where p.freq > 0 {
            if let l = px.last, log(p.freq) <= l { py[py.count - 1] = p.gainDB; continue }
            px.append(log(p.freq)); py.append(p.gainDB)
        }

        var re = [Double](repeating: 0, count: n)
        var im = [Double](repeating: 0, count: n)
        let k20 = log(10.0) / 20
        if !px.isEmpty {
            var seg = 0
            for k in 0...half {
                let lf = log(max(Double(k) * fs / Double(n), 1e-3))
                var db: Double
                if lf <= px[0] { db = py[0] }
                else if lf >= px[px.count - 1] { db = py[py.count - 1] }
                else {
                    while seg + 1 < px.count - 1 && px[seg + 1] < lf { seg += 1 }
                    let t = (lf - px[seg]) / (px[seg + 1] - px[seg])
                    db = py[seg] + t * (py[seg + 1] - py[seg])
                }
                re[k] = db * k20
                if k > 0 && k < half { re[n - k] = re[k] }
            }
        }
        guard let setup = vDSP_create_fftsetupD(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else {
            var h = [Double](repeating: 0, count: taps); h[0] = 1; return h
        }
        defer { vDSP_destroy_fftsetupD(setup) }

        func fft(_ inverse: Bool) {
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var sc = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zipD(setup, &sc, 1, vDSP_Length(log2n),
                                  inverse ? FFTDirection(kFFTDirection_Inverse) : FFTDirection(kFFTDirection_Forward))
                }
            }
        }
        let inv = 1.0 / Double(n)

        // real cepstrum of the log magnitude
        fft(true)
        for i in 0..<n { re[i] *= inv; im[i] = 0 }
        for i in 1..<half { re[i] *= 2 }
        for i in (half + 1)..<n { re[i] = 0 }
        // spectrum of the folded cepstrum = log of the minimum-phase response
        fft(false)
        for k in 0...half {
            let m = exp(re[k])
            let ph = (k == 0 || k == half) ? 0 : im[k]
            re[k] = m * cos(ph); im[k] = m * sin(ph)
        }
        // numpy irfft semantics: Hermitian completion, DC / Nyquist imaginary parts ignored
        im[0] = 0; im[half] = 0
        for k in 1..<half { re[n - k] = re[k]; im[n - k] = -im[k] }
        fft(true)

        var h = [Double](repeating: 0, count: taps)
        for i in 0..<taps { h[i] = re[i] * inv }
        let fade = taps / 8
        for i in 0..<fade {
            let t = Double(i) / Double(fade - 1) * Double.pi
            h[taps - fade + i] *= 0.5 * (1 + cos(t))
        }
        return h
    }
}
