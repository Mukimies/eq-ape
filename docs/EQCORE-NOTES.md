# EQCore notes

Package: `EQCore/` (swift-tools 5.9, macOS 14, library `EQCore`, tests `EQCoreTests`). `swift test`: 19 tests, 0 failures.

## Implemented
- `APOParser`: Preamp, Filter (PK/PEQ/MODAL, LSC/HSC/LS/HS, LP/HP/LPQ/HPQ, NO, AP, BP; "None" and OFF skipped silently),
  GraphicEQ (sorted by frequency), Channel (L/R/1/2/all), Include (relative to the including file, spaces/parens, backslashes
  converted, depth limit 16), `#` comments, decimal commas, BW Oct -> Q, shelf slope form (`HSC 12 dB Fc ...`), UTF-8 (+BOM),
  UTF-16 (BOM LE/BE), CRLF. Every other non-blank line gives a warning (`file:line: ...`). Warnings include REW header lines.
  `parse(text:baseURL:)`: `baseURL` is the Include base directory (if it is an existing file, its parent is used).
- `Response` (`magnitudeDB`, `peak`) as reference (`chain_db`/`peak_db`, 4000 points 5 Hz-22 kHz; HP/LP/notch/AP/BP = 0 dB).
  Kept for compatibility; anti-clipping no longer uses them (see "Anti-clipping" below).
  Extra helpers: `Response.exactMagnitudeDB`, `designBiquad`, `GraphicEQDesigner.{design, merge, interpolateDB}`, and since
  2026-11-12 `Response.{chainPeak, chainMagnitudeDB, antiClipSearchRange}`, `EQProcessor.antiClipGainDB`,
  `GraphicEQDesigner.{designedKernel, mergedCurve}`, `FIRMagnitude` (all additive, in `AntiClip.swift`).
- `GraphicEQDesigner.design`: cepstral min-phase FIR, 32768 taps, FFT 8x, cosine fade on last eighth, vDSP double FFT.
- `EQProcessor`: per channel biquads (vDSP_biquadD, Double) -> gain -> FIR. All gains are folded into one scalar and ALL
  GraphicEQ stages of a channel are merged into one FIR (dB curves summed). Identical FIRs on L/R share one kernel.
  Channel 0 uses `left`, all others `right`.
- FIR: uniformly partitioned (B = 256) convolution with a direct-form head (first 256 taps via vDSP_conv) and FFT tail
  (frequency delay line, overlap-save, real FFT 512). Any `frames` 1...maxFrames (larger is chunked) is handled.
- Headroom: gain = min over left/right of (-headroomDB - peak), only if negative; the MORE NEGATIVE value is applied to all
  channels (keeps stereo balance). Not rounded (reference rounds to 2 decimals). The peak is `Response.chainPeak` (full
  chain) since 2026-11-12; before, it was the reference `Response.peak`.
- `peakLinear` (read resets) / `clippedSamples`: plain aligned stores in raw memory (no `Atomic` before macOS 15); benign race
  documented in code. Output is never clamped.

## Latency
FIR latency: **0 samples** (verified against direct convolution, max error < 1e-4, for mixed block sizes 1...1024).

## Performance (stereo 48 kHz, 10 s, 512-frame blocks, full real config + 0.5 dB headroom, one thread)
CPU 0.129 s in debug (`swift test`), 0.056 s in release (`swift test -c release`).

## Deviations / notes
- Stages are reordered internally (LTI stages commute; gains folded, all FIRs merged): rounding differs only.
- Biquads with freq <= 0 or >= Nyquist are skipped (identity), also in `Response`.
- Frequency-response tests measure the impulse response with a direct DTFT (exact) rather than an FFT; same information.
- Headroom gain is unrounded; LS/HS produce the reference's "corner vs centre" warning.
- FIR design takes ~0.1-0.2 s per curve (done in `init`, not real-time). Designed at the stream rate.

## Known gaps
- No sample-rate change handling (create a new processor); no Windows-style `Device:`/`If:`/`Copy:` lines (warned).
- `vDSP_biquadD` delay state is not denormal-flushed.
- Convolution runs in Float; the designed FIR is rounded to Float.

## Changes after the parity audit (see docs/APO-PARITY.md)
Audit against the real Equalizer APO source (GPL-2.0-or-later; behaviour re-implemented, no code copied). `swift test`: 29 tests, 0 failures.
- New additive field `BiquadSpec.bandwidthOct`; "BW Oct" now uses APO's `alpha = sin w sinh(ln2/2 BW w/sin w)` instead of the Q conversion; BW ignored for shelves.
- Default shelf (no Q, no slope) is S = 0.9 = 10.8 dB/oct (was 12); `designBiquad` default likewise.
- LS/HS (non-"C") with an explicit Q or slope: parser converts the corner frequency to the centre frequency (APO formula); no more warning.
- PK/AP without Q or BW, and PK/LS/HS without Gain, are dropped with a warning (as APO). LP/HP/BP default Q is exactly 1/sqrt(2).
- Command names, `ON`, filter type names and the Fc/Gain/Q/Hz/dB labels are case sensitive (as APO); mismatches are warned.
- Preamp takes the number only (`Preamp: -6 db` / `-6` work, as in APO); GraphicEQ is tokenised like APO (separators optional);
  `Fc 1.000 Hz` thousands-separator quirk; Channel selection is restored at the end of an Include; include depth limit 100.
- Tests changed (each shown wrong by the source): `testFilterTypes`, `testDecimalCommaAndBandwidth`; 10 new tests in `ParityTests.swift`.
- A real-world Equalizer APO config (not included in the repository): same 7 stages before and after; response unchanged at 20/30/40/63/100/118 Hz
  (Response.magnitudeDB: 10.093, 9.879, 9.290, -4.016, -3.224, -16.150 dB; exactMagnitudeDB incl. HPQ: -4.161, 6.869, 8.876, -4.027, -3.225, -16.150 dB; 48 kHz).
- Not done (documented gaps): Copy, Delay, Convolution, Device, If/Eval, IIR.

## Anti-clipping: full-chain peak (2026-11-12)

**Change.** The automatic anti-clipping gain used to come from `Response.peak`, which (as the early reference script)
counted high-pass, low-pass, notch, all-pass and band-pass filters as 0 dB. For the owner's config (two peaking cuts,
-1 dB preamp, two GraphicEQ bass boosts summing to +11.2 dB at and below 40 Hz, a 4th-order Butterworth high-pass at
30 Hz made of two HPQ biquads) it found +10.19 dB at 5 Hz, a region the high-pass removes, and applied **-10.69 dB**.
`EQProcessor` and the editor now use `EQProcessor.antiClipGainDB` / `Response.chainPeak`:

- Every stage counts exactly: gains; every biquad kind with its exact magnitude (a high-pass removes the bass below it,
  and a resonant high-pass or low-pass adds its peak, which the old search missed: a Q 2 high-pass is +6.30 dB); and the
  GraphicEQ stages as the processor plays them (below).
- Range: **1 Hz to 0.999 x Nyquist** (23.976 kHz at 48 kHz, 47.95 kHz at 96 kHz). The upper end follows the sample rate
  because high-rate streams carry content above 22 kHz, and high shelves keep rising towards Nyquist. The lower end is
  below the old 5 Hz on purpose: a boost there is a real boost of whatever DC drift or rumble a recording has, and
  realistic configs are flat or falling below 5 Hz, so this costs nothing in practice.
- Grid: 4000 log-spaced points, plus each biquad's centre/corner frequency and points 1/96 octave apart within ±1/2
  octave of it, plus every GraphicEQ node and its 1/96-octave neighbours. The 8 highest local maxima are refined by
  golden-section search in log frequency.
- Owner's config (scratch copy, 48 kHz, headroom 0.5 dB): **peak +8.910 dB at 39.55 Hz, gain -9.410 dB** (was +10.194 dB
  at 5 Hz, -10.694 dB). 44.1 kHz: +8.909 dB at 39.53 Hz; 96 kHz: +8.926 dB at 39.01 Hz. The EQ now plays 1.28 dB louder.

**GraphicEQ: interpolated curve vs the real FIR.** The FIR (32768-tap minimum phase) does not follow the ideal curve
(linear in dB over log f) exactly: at steep corners it overshoots, and it cannot resolve detail narrower than about
fs/32768 (1.5 Hz at 48 kHz), which matters at very low frequencies. Measured (DTFT of the designed kernel, dense log
grid 0.5 Hz - Nyquist plus ±1/6 octave around every node):

| Curve | 44.1 kHz | 48 kHz | 96 kHz |
|---|---|---|---|
| Owner's two curves summed: real above interpolated, worst | +0.039 dB (50 Hz) | +0.043 dB (50 Hz) | +0.096 dB (50 Hz) |
| Same, real maximum vs ideal maximum (11.2 dB) | +0.018 | +0.019 | +0.039 |
| Step +12 dB over 1/6 octave at 1 kHz | +0.008 | +0.008 | +0.017 |
| Spike +12 dB, ±1/6 octave at 100 Hz (flank) | +0.08 | +0.08 | +0.20 |
| Spike +12 dB at 30 Hz (flank) | +0.40 | +0.38 | +0.75 |
| Spike +12 dB at 10 Hz (flank) | +1.13 | +1.32 | +4.19 |

For the owner's curves the interpolated curve was within 0.1 dB, but for narrow or low-frequency curves it
under-estimates the real response by more than 1 dB on the flanks, where a biquad boost could sit. So the peak search
does not use the interpolated curve: it **measures the FIR the processor runs**. `GraphicEQDesigner.designedKernel`
designs the merged curve once (memoised, last 8 curves), and `FIRMagnitude` takes its 8x zero-padded FFT (bins fs/262144
apart, 0.18 Hz at 48 kHz), read with linear interpolation in dB. `EQProcessor` uses the same memoised kernel, so the
search measures exactly the taps that are convolved. Sine sweeps through `EQProcessor` matched the measured response
within 0.0015 dB (bin interpolation plus Float32 convolution), so `chainPeak` adds a **0.01 dB allowance** when a FIR is
present (`Response.firMeasurementAllowanceDB`); biquad-only chains are exact. Cost: about 10-20 ms per new curve in a
release build (design plus FFT), 0.5 ms when cached.

**Empirical check** (real `EQProcessor`, owner's config, 48 kHz, headroom 0.5 dB, 512-frame blocks, steady state):
- Full-scale (peak 1.0) sines from 39.0 to 40.2 Hz in 0.05 Hz steps: worst output **-0.509 dBFS** at 39.50 Hz, -0.510
  at the predicted 39.55 Hz; each frequency within 0.003 dB of the prediction. Without the allowance the worst was
  -0.499 dBFS, 0.001 dB above the target, which is why the allowance exists.
- Sines 20-80 Hz in 0.5 Hz steps and at 100 Hz-15 kHz: none above -0.509 dBFS (30 Hz -2.53, 35 Hz -0.85, 45 Hz -4.24,
  50 Hz -8.37, 1 kHz -10.42 dBFS).
- White noise, 40 s, transfer function H = Sxy/Sxx (65536-point Hann segments): within 0.07 dB of `chainMagnitudeDB`
  from 20 Hz to 1 kHz (for example 30.03 Hz -2.504 vs -2.514, 49.80 Hz -8.233 vs -8.234, 999.76 Hz -10.406 vs -10.406).
  The noise estimate's own variance is about ±0.05 dB per bin.

**What frequency-domain headroom does not do.** It guarantees that no *steady sine* at full scale leaves the EQ above
-headroom dBFS. It does not bound *sample peaks* of real music: an EQ (even a pure cut or an all-pass) shifts the phase of
the components differently, and for already-limited masters whose peaks sit at 0 dBFS that can raise sample peaks by a
few dB (inter-component phase alignment, not a level boost). The processor never clamps; such overs are counted by the
existing clip counter (`clippedSamples`, the clip light in the editor). Extra headroom in the profile reduces them. This
change does not try to solve that.

Tests: `AntiClipTests.swift` (6 tests: high-pass only gives no boost and never a positive gain, Q 2 high-pass matches its
analytic resonant peak and a sine through the processor, the owner-like boost-then-high-pass checked against the
processor's impulse response and with sines, different left/right peaks and mono, narrow peaks and the sample-rate
range, FIR measured vs interpolated); `testPeakAndHeadroom` now asserts -9.41 dB (was -10.69) and keeps the reference
+10.19 dB for `Response.peak`. `swift test`: 50 tests, 0 failures (2 skipped without `EQAPE_REAL_CONFIG`).
