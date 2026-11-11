import Foundation
import Accelerate

/// Immutable, shareable FIR data for zero-latency partitioned convolution.
///
/// Scheme: block size B. Taps 0..<B ("head") are convolved directly in the time domain with the
/// current input block (vDSP_conv), so output sample t is available as soon as input sample t is.
/// Taps B... are split into partitions of B taps; their contribution to block j+1 depends only on
/// blocks <= j, so it is computed by FFT (frequency-delay-line, overlap-save, FFT size 2B) when
/// block j completes. Total latency: 0 samples, for any call size 1...maxFrames.
final class FIRKernel {
    static let B = 256
    let B = FIRKernel.B
    let log2N: vDSP_Length
    let setup: FFTSetup
    let tailPartitions: Int
    let headRev: UnsafeMutablePointer<Float>    // taps 0..<B, reversed (for vDSP_conv correlation)
    let hRe: UnsafeMutablePointer<Float>        // tailPartitions * B (packed split spectra, scaled)
    let hIm: UnsafeMutablePointer<Float>
    let tapCount: Int

    init?(taps: [Float]) {
        let B = FIRKernel.B, N = 2 * B
        tapCount = taps.count
        log2N = vDSP_Length(Int(log2(Double(N))))
        guard let s = vDSP_create_fftsetup(log2N, FFTRadix(kFFTRadix2)) else { return nil }
        setup = s
        let P = max(1, (taps.count + B - 1) / B)
        tailPartitions = P - 1
        headRev = .allocate(capacity: B); headRev.initialize(repeating: 0, count: B)
        for k in 0..<min(B, taps.count) { headRev[B - 1 - k] = taps[k] }
        let cap = max(1, tailPartitions * B)
        hRe = .allocate(capacity: cap); hRe.initialize(repeating: 0, count: cap)
        hIm = .allocate(capacity: cap); hIm.initialize(repeating: 0, count: cap)
        let tbuf = UnsafeMutablePointer<Float>.allocate(capacity: N); defer { tbuf.deallocate() }
        var scale = 1 / Float(4 * N)   // vDSP real FFT: forward x2, inverse x N; two forwards in a product
        for q in 1..<P where P > 1 {
            tbuf.initialize(repeating: 0, count: N)
            let lo = q * B, hi = min(lo + B, taps.count)
            for i in lo..<hi { tbuf[i - lo] = taps[i] }
            var sp = DSPSplitComplex(realp: hRe + (q - 1) * B, imagp: hIm + (q - 1) * B)
            tbuf.withMemoryRebound(to: DSPComplex.self, capacity: B) { vDSP_ctoz($0, 2, &sp, 1, vDSP_Length(B)) }
            vDSP_fft_zrip(setup, &sp, 1, log2N, FFTDirection(kFFTDirection_Forward))
            vDSP_vsmul(sp.realp, 1, &scale, sp.realp, 1, vDSP_Length(B))
            vDSP_vsmul(sp.imagp, 1, &scale, sp.imagp, 1, vDSP_Length(B))
        }
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        headRev.deallocate(); hRe.deallocate(); hIm.deallocate()
    }
}

/// Per-channel convolution state. `process` allocates nothing and takes no locks.
final class FIRConvolver {
    private let kernel: FIRKernel
    private let B: Int
    private let T: Int
    private let frame: UnsafeMutablePointer<Float>     // [previous block | current block]
    private let tail: UnsafeMutablePointer<Float>      // FFT-part contribution to current block
    private let fdlRe: UnsafeMutablePointer<Float>
    private let fdlIm: UnsafeMutablePointer<Float>
    private let accRe: UnsafeMutablePointer<Float>
    private let accIm: UnsafeMutablePointer<Float>
    private let tbuf: UnsafeMutablePointer<Float>
    private var fill = 0
    private var newest = 0

    init(kernel: FIRKernel) {
        self.kernel = kernel
        B = kernel.B; T = kernel.tailPartitions
        func alloc(_ n: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: max(1, n)); p.initialize(repeating: 0, count: max(1, n)); return p
        }
        frame = alloc(2 * B); tail = alloc(B); tbuf = alloc(2 * B)
        fdlRe = alloc(T * B); fdlIm = alloc(T * B); accRe = alloc(B); accIm = alloc(B)
    }

    deinit {
        for p in [frame, tail, tbuf, fdlRe, fdlIm, accRe, accIm] { p.deallocate() }
    }

    func process(_ data: UnsafeMutablePointer<Float>, frames n: Int) {
        var done = 0
        while done < n {
            let c = min(n - done, B - fill)
            (frame + B + fill).update(from: data + done, count: c)
            // head: y[p] = sum_k h[k] * frame[B + p - k]
            vDSP_conv(frame + 1 + fill, 1, kernel.headRev, 1, data + done, 1, vDSP_Length(c), vDSP_Length(B))
            vDSP_vadd(data + done, 1, tail + fill, 1, data + done, 1, vDSP_Length(c))
            fill += c; done += c
            if fill == B { completeBlock() }
        }
    }

    private func completeBlock() {
        defer {
            frame.update(from: frame + B, count: B)
            fill = 0
        }
        if T == 0 { return }
        let B = self.B
        newest += 1; if newest == T { newest = 0 }
        var x = DSPSplitComplex(realp: fdlRe + newest * B, imagp: fdlIm + newest * B)
        frame.withMemoryRebound(to: DSPComplex.self, capacity: B) { vDSP_ctoz($0, 2, &x, 1, vDSP_Length(B)) }
        vDSP_fft_zrip(kernel.setup, &x, 1, kernel.log2N, FFTDirection(kFFTDirection_Forward))

        accRe.update(repeating: 0, count: B); accIm.update(repeating: 0, count: B)
        var acc1 = DSPSplitComplex(realp: accRe + 1, imagp: accIm + 1)
        var slot = newest
        for a in 0..<T {
            let xr = fdlRe + slot * B, xi = fdlIm + slot * B
            let hr = kernel.hRe + a * B, hi = kernel.hIm + a * B
            // bin 0 packs DC (real) and Nyquist (imag): independent real products
            accRe[0] += xr[0] * hr[0]
            accIm[0] += xi[0] * hi[0]
            var xs = DSPSplitComplex(realp: xr + 1, imagp: xi + 1)
            var hs = DSPSplitComplex(realp: hr + 1, imagp: hi + 1)
            vDSP_zvma(&xs, 1, &hs, 1, &acc1, 1, &acc1, 1, vDSP_Length(B - 1))
            slot -= 1; if slot < 0 { slot = T - 1 }
        }
        var acc = DSPSplitComplex(realp: accRe, imagp: accIm)
        vDSP_fft_zrip(kernel.setup, &acc, 1, kernel.log2N, FFTDirection(kFFTDirection_Inverse))
        tbuf.withMemoryRebound(to: DSPComplex.self, capacity: B) { vDSP_ztoc(&acc, 1, $0, 2, vDSP_Length(B)) }
        tail.update(from: tbuf + B, count: B)   // overlap-save: second half is alias-free
    }
}
