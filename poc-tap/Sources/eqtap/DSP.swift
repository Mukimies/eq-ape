import Foundation

/// The single processing hook. Non-interleaved Float buffers, processed in place.
/// Signature intentionally matches EQCore's `EQProcessor.process(_:frames:)` (plus channel count),
/// so EQCore can be plugged in later as:
///     let eq = EQProcessor(config:..., sampleRate:..., channels:..., headroomDB:..., maxFrames:...)
///     let fn: ProcessFn = { bufs, _, frames in eq.process(bufs, frames: frames) }
/// Must be real-time safe: no allocation, no locks, no ObjC/Swift runtime calls that may block.
typealias ProcessFn = (_ channelData: UnsafePointer<UnsafeMutablePointer<Float>>, _ channels: Int, _ frames: Int) -> Void

struct PeakSpec { var freq: Double; var gainDB: Double; var q: Double }

/// PoC processor: gain followed by RBJ peaking biquads (transposed direct form II, Double state).
/// All memory is allocated in init; process() only touches preallocated storage.
final class PoCProcessor {
    private let channels: Int
    private let nStages: Int
    private let gain: Float
    // coefficients per stage: b0,b1,b2,a1,a2 (normalised by a0)
    private let coef: UnsafeMutablePointer<Double>
    // state per (channel, stage): z1, z2
    private let state: UnsafeMutablePointer<Double>

    init(sampleRate: Double, channels: Int, gainDB: Double, peaks: [PeakSpec]) {
        self.channels = channels
        self.nStages = peaks.count
        self.gain = Float(pow(10.0, gainDB / 20.0))
        coef = .allocate(capacity: max(1, peaks.count * 5))
        state = .allocate(capacity: max(1, peaks.count * channels * 2))
        state.initialize(repeating: 0, count: max(1, peaks.count * channels * 2))
        for (i, p) in peaks.enumerated() {
            // RBJ Audio EQ Cookbook, peakingEQ
            let A = pow(10.0, p.gainDB / 40.0)
            let w0 = 2.0 * Double.pi * p.freq / sampleRate
            let alpha = sin(w0) / (2.0 * p.q)
            let cw = cos(w0)
            let a0 = 1.0 + alpha / A
            coef[i * 5 + 0] = (1.0 + alpha * A) / a0
            coef[i * 5 + 1] = (-2.0 * cw) / a0
            coef[i * 5 + 2] = (1.0 - alpha * A) / a0
            coef[i * 5 + 3] = (-2.0 * cw) / a0
            coef[i * 5 + 4] = (1.0 - alpha / A) / a0
        }
    }

    deinit {
        coef.deallocate()
        state.deallocate()
    }

    func process(_ bufs: UnsafePointer<UnsafeMutablePointer<Float>>, _ chs: Int, _ frames: Int) {
        let nch = min(chs, channels)
        for c in 0..<nch {
            let x = bufs[c]
            if gain != 1 { for n in 0..<frames { x[n] *= gain } }
            for s in 0..<nStages {
                let b0 = coef[s * 5], b1 = coef[s * 5 + 1], b2 = coef[s * 5 + 2]
                let a1 = coef[s * 5 + 3], a2 = coef[s * 5 + 4]
                let st = state + (c * nStages + s) * 2
                var z1 = st[0], z2 = st[1]
                for n in 0..<frames {
                    let xin = Double(x[n])
                    let y = b0 * xin + z1
                    z1 = b1 * xin - a1 * y + z2
                    z2 = b2 * xin - a2 * y
                    x[n] = Float(y)
                }
                // flush denormals
                if abs(z1) < 1e-30 { z1 = 0 }
                if abs(z2) < 1e-30 { z2 = 0 }
                st[0] = z1; st[1] = z2
            }
        }
    }
}
