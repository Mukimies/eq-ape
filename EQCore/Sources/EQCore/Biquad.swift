import Foundation

/// Normalised biquad coefficients (a0 == 1): y = b0 x + b1 x1 + b2 x2 - a1 y1 - a2 y2.
public struct BiquadCoeffs: Equatable, Sendable {
    public var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
}

/// RBJ audio-EQ-cookbook design, same formulas as the reference. Returns nil when the
/// frequency is not in (0, Nyquist) so callers can treat the stage as a no-op.
public func designBiquad(_ p: BiquadSpec, sampleRate fs: Double) -> BiquadCoeffs? {
    guard p.freq > 0, p.freq < fs / 2, fs > 0 else { return nil }
    let A = pow(10, p.gainDB / 40)
    let w = 2 * Double.pi * p.freq / fs
    let c = cos(w), sn = sin(w)
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0
    func alphaQ(_ dflt: Double) -> Double {
        // Equalizer APO BiQuad.cpp: "BW" branch for non-shelf filters, otherwise Q.
        if let bw = p.bandwidthOct, bw != 0 { return sn * sinh(M_LN2 / 2 * bw * w / sn) }
        return sn / (2 * (p.q ?? dflt))
    }
    switch p.kind {
    case .peaking:
        let al = alphaQ(0.707)
        b0 = 1 + al * A; b1 = -2 * c; b2 = 1 - al * A
        a0 = 1 + al / A; a1 = -2 * c; a2 = 1 - al / A
    case .lowShelf, .highShelf:
        let al: Double
        if let q = p.q { al = sn / (2 * q) }
        else {
            let S = (p.slopeDBPerOct ?? 10.8) / 12   // Equalizer APO default shelf S = 0.9
            al = sn / 2 * (max(0, (A + 1 / A) * (1 / S - 1) + 2)).squareRoot()
        }
        let sq = 2 * A.squareRoot() * al
        let sg: Double = p.kind == .lowShelf ? 1 : -1
        b0 = A * ((A + 1) - sg * (A - 1) * c + sq)
        b1 = sg * 2 * A * ((A - 1) - sg * (A + 1) * c)
        b2 = A * ((A + 1) - sg * (A - 1) * c - sq)
        a0 = (A + 1) + sg * (A - 1) * c + sq
        a1 = -sg * 2 * ((A - 1) + sg * (A + 1) * c)
        a2 = (A + 1) + sg * (A - 1) * c - sq
    case .lowPass:
        let al = alphaQ(0.7071)
        b0 = (1 - c) / 2; b1 = 1 - c; b2 = (1 - c) / 2
        a0 = 1 + al; a1 = -2 * c; a2 = 1 - al
    case .highPass:
        let al = alphaQ(0.7071)
        b0 = (1 + c) / 2; b1 = -(1 + c); b2 = (1 + c) / 2
        a0 = 1 + al; a1 = -2 * c; a2 = 1 - al
    case .notch:
        let al = alphaQ(30)
        b0 = 1; b1 = -2 * c; b2 = 1
        a0 = 1 + al; a1 = -2 * c; a2 = 1 - al
    case .allPass:
        let al = alphaQ(0.7071)
        b0 = 1 - al; b1 = -2 * c; b2 = 1 + al
        a0 = 1 + al; a1 = -2 * c; a2 = 1 - al
    case .bandPass:   // constant 0 dB peak gain
        let al = alphaQ(0.7071)
        b0 = al; b1 = 0; b2 = -al
        a0 = 1 + al; a1 = -2 * c; a2 = 1 - al
    }
    return BiquadCoeffs(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
}

extension BiquadCoeffs {
    /// |H(e^{jw})| in dB.
    public func magnitudeDB(freq: Double, sampleRate fs: Double) -> Double {
        let w = 2 * Double.pi * freq / fs
        let c1 = cos(w), s1 = -sin(w), c2 = cos(2 * w), s2 = -sin(2 * w)
        let nr = b0 + b1 * c1 + b2 * c2, ni = b1 * s1 + b2 * s2
        let dr = 1 + a1 * c1 + a2 * c2, di = a1 * s1 + a2 * s2
        let num = nr * nr + ni * ni, den = dr * dr + di * di
        return 10 * log10(max(num, 1e-300) / max(den, 1e-300))
    }
}

/// Frequency response of a stage chain.
///
/// `magnitudeDB` and `peak` follow the reference (`chain_db`/`peak_db`): only gain, peaking, shelf and
/// GraphicEQ stages contribute; high/low-pass, notch, all-pass and band-pass count as 0 dB.
/// `exactMagnitudeDB` evaluates every biquad kind.
public enum Response {

    struct Evaluator {
        var gainDB = 0.0
        var biquads: [BiquadCoeffs] = []
        var geq: [[GraphicEQPoint]] = []

        init(stages: [Stage], sampleRate: Double, exact: Bool) {
            for st in stages {
                switch st {
                case .gain(let g): gainDB += g
                case .biquad(let s):
                    let counts = exact || s.kind == .peaking || s.kind == .lowShelf || s.kind == .highShelf
                    if counts, let c = designBiquad(s, sampleRate: sampleRate) { biquads.append(c) }
                case .graphicEQ(let pts):
                    if !pts.isEmpty { geq.append(pts.sorted { $0.freq < $1.freq }) }
                }
            }
        }

        func eval(_ f: Double, _ fs: Double) -> Double {
            var t = gainDB
            for c in biquads { t += c.magnitudeDB(freq: f, sampleRate: fs) }
            for p in geq { t += GraphicEQDesigner.interpolateDB(p, f) }
            return t
        }
    }

    public static func magnitudeDB(stages: [Stage], freq: Double, sampleRate: Double) -> Double {
        Evaluator(stages: stages, sampleRate: sampleRate, exact: false).eval(freq, sampleRate)
    }

    public static func exactMagnitudeDB(stages: [Stage], freq: Double, sampleRate: Double) -> Double {
        Evaluator(stages: stages, sampleRate: sampleRate, exact: true).eval(freq, sampleRate)
    }

    /// Peak over 4000 log-spaced points from 5 Hz to 22 kHz (as the reference).
    public static func peak(stages: [Stage], sampleRate: Double) -> (dB: Double, freq: Double) {
        let ev = Evaluator(stages: stages, sampleRate: sampleRate, exact: false)
        let n = 4000
        var best = (dB: -Double.infinity, freq: 5.0)
        for i in 0..<n {
            let f = 5 * pow(22000.0 / 5.0, Double(i) / Double(n - 1))
            let d = ev.eval(f, sampleRate)
            if d >= best.dB { best = (d, f) }
        }
        return best
    }
}
