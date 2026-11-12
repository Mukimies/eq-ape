import Foundation
import Accelerate

/// Per-channel chain: biquad cascade (Double, vDSP_biquadD, direct form II) -> linear gain -> merged FIR.
/// All LTI stages commute, so gains are folded into one scalar and all GraphicEQ stages of a channel
/// into one FIR (dB curves summed); this only changes floating-point rounding, not the response.
final class ChannelDSP {
    private let maxFrames: Int
    private let nBiquads: Int
    private let coeffs: UnsafeMutablePointer<Double>   // 5 per biquad: b0 b1 b2 a1 a2
    private let delay: UnsafeMutablePointer<Double>    // vDSP_biquadD delay line: 2 * sections + 2
    private let work: UnsafeMutablePointer<Double>
    private let work2: UnsafeMutablePointer<Double>
    private let setup: vDSP_biquad_SetupD?
    private var gainLin: Double
    private let fir: FIRConvolver?

    init(biquads: [BiquadCoeffs], gainDB: Double, kernel: FIRKernel?, maxFrames: Int) {
        self.maxFrames = maxFrames
        nBiquads = biquads.count
        coeffs = .allocate(capacity: max(1, 5 * nBiquads)); coeffs.initialize(repeating: 0, count: max(1, 5 * nBiquads))
        delay = .allocate(capacity: 2 * nBiquads + 2); delay.initialize(repeating: 0, count: 2 * nBiquads + 2)
        work = .allocate(capacity: maxFrames); work.initialize(repeating: 0, count: maxFrames)
        work2 = .allocate(capacity: maxFrames); work2.initialize(repeating: 0, count: maxFrames)
        for (i, b) in biquads.enumerated() {
            coeffs[5 * i] = b.b0; coeffs[5 * i + 1] = b.b1; coeffs[5 * i + 2] = b.b2
            coeffs[5 * i + 3] = b.a1; coeffs[5 * i + 4] = b.a2
        }
        setup = nBiquads > 0 ? vDSP_biquad_CreateSetupD(coeffs, vDSP_Length(nBiquads)) : nil
        gainLin = pow(10, gainDB / 20)
        fir = kernel.map { FIRConvolver(kernel: $0) }
    }

    deinit {
        if let s = setup { vDSP_biquad_DestroySetupD(s) }
        coeffs.deallocate(); delay.deallocate(); work.deallocate(); work2.deallocate()
    }

    func process(_ data: UnsafeMutablePointer<Float>, frames: Int) {
        var off = 0
        while off < frames {
            let n = min(maxFrames, frames - off)
            processChunk(data + off, n)
            off += n
        }
    }

    private func processChunk(_ p: UnsafeMutablePointer<Float>, _ n: Int) {
        if nBiquads > 0 || gainLin != 1 {
            vDSP_vspdp(p, 1, work, 1, vDSP_Length(n))
            var src = work
            if let s = setup {
                vDSP_biquadD(s, delay, work, 1, work2, 1, vDSP_Length(n))   // not in place
                src = work2
            }
            if gainLin != 1 {
                var g = gainLin
                vDSP_vsmulD(src, 1, &g, src, 1, vDSP_Length(n))
            }
            vDSP_vdpsp(src, 1, p, 1, vDSP_Length(n))
        }
        fir?.process(p, frames: n)
    }
}

/// One instance per stream. `process` is real-time safe: no allocation, no locks, everything
/// is preallocated in `init`.
///
/// Latency: **0 samples** (head of the FIR is direct-form; the FFT tail only feeds later blocks).
///
/// Threading of statistics: `peakLinear` / `clippedSamples` are plain aligned stores into raw memory,
/// written only by the audio thread and read from any thread. Swift 5.9/macOS 14 has no `Atomic`
/// (the Synchronization module needs macOS 15) and a C atomics target is overkill here; aligned
/// 32/64-bit loads and stores are atomic on arm64 and x86-64, so readers see either the old or the new
/// value, never a torn one. The only race is `peakLinear`'s reset vs a concurrent audio-thread update,
/// which can drop at most one block's peak: benign for metering.
public final class EQProcessor: @unchecked Sendable {
    private let channelCount: Int
    private let chans: [ChannelDSP]
    private let peaks: UnsafeMutablePointer<Float>
    private let clips: UnsafeMutablePointer<UInt64>
    private let headroomGain: Double

    /// Headroom gain actually appended (dB, <= 0). If left and right chains need different gains, the
    /// MORE NEGATIVE of the two is applied to every channel, so the stereo balance is preserved.
    public var appliedHeadroomGainDB: Double { headroomGain }

    /// Per-channel peak of |output| since the previous read. Reading resets the peaks to 0.
    public var peakLinear: [Float] {
        var out = [Float](repeating: 0, count: channelCount)
        for c in 0..<channelCount { out[c] = peaks[c]; peaks[c] = 0 }
        return out
    }

    /// Count of output samples with |x| >= 1.0 since creation.
    public var clippedSamples: UInt64 {
        var t: UInt64 = 0
        for c in 0..<channelCount { t &+= clips[c] }
        return t
    }

    public init(config: EQConfig, sampleRate: Double, channels: Int, headroomDB: Double?, maxFrames: Int) {
        let nch = max(1, channels)
        channelCount = nch
        let maxF = max(1, maxFrames)

        // Full-chain peak (every biquad kind and the measured FIR response), see AntiClip.swift.
        let headroom = EQProcessor.antiClipGainDB(config: config, sampleRate: sampleRate, channels: nch, headroomDB: headroomDB)
        headroomGain = headroom

        var kernels: [(points: [GraphicEQPoint], kernel: FIRKernel?)] = []
        func build(_ stages: [Stage]) -> ChannelDSP {
            var gain = headroom
            var bqs: [BiquadCoeffs] = []
            var curves: [[GraphicEQPoint]] = []
            for st in stages {
                switch st {
                case .gain(let g): gain += g
                case .biquad(let s): if let c = designBiquad(s, sampleRate: sampleRate) { bqs.append(c) }
                case .graphicEQ(let p): if !p.isEmpty { curves.append(p) }
                }
            }
            var kernel: FIRKernel?
            if !curves.isEmpty, let merged = GraphicEQDesigner.mergedCurve(of: stages) {
                if let hit = kernels.first(where: { $0.points == merged }) { kernel = hit.kernel }
                else {
                    // the same (memoised) design the anti-clipping peak search measured
                    let h = GraphicEQDesigner.designedKernel(points: merged, sampleRate: sampleRate).taps
                    kernel = FIRKernel(taps: h.map { Float($0) })
                    kernels.append((merged, kernel))
                }
            }
            return ChannelDSP(biquads: bqs, gainDB: gain, kernel: kernel, maxFrames: maxF)
        }
        let l = build(config.left)
        let r = config.right == config.left ? nil : build(config.right)
        var list: [ChannelDSP] = []
        for c in 0..<nch {
            if c == 0 { list.append(l) }
            else if let r = r, c == 1 { list.append(r) }
            else if c == 1 { list.append(build(config.right)) }
            else { list.append(build(config.right)) }   // channels beyond the second share the right chain (own state)
        }
        chans = list
        peaks = .allocate(capacity: nch); peaks.initialize(repeating: 0, count: nch)
        clips = .allocate(capacity: nch); clips.initialize(repeating: 0, count: nch)
    }

    deinit { peaks.deallocate(); clips.deallocate() }

    /// Non-interleaved, in place. Any `frames` is accepted (chunked internally if above `maxFrames`).
    public func process(_ channelData: UnsafePointer<UnsafeMutablePointer<Float>>, frames: Int) {
        if frames <= 0 { return }
        for c in 0..<channelCount {
            let p = channelData[c]
            chans[c].process(p, frames: frames)
            var m: Float = 0
            vDSP_maxmgv(p, 1, &m, vDSP_Length(frames))
            if m > peaks[c] { peaks[c] = m }
            if m >= 1.0 {
                var n: UInt64 = 0
                for i in 0..<frames where abs(p[i]) >= 1.0 { n += 1 }
                clips[c] = clips[c] &+ n
            }
        }
    }
}
