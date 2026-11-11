# EQCore notes

Package: `EQCore/` (swift-tools 5.9, macOS 14, library `EQCore`, tests `EQCoreTests`). `swift test`: 19 tests, 0 failures.

## Implemented
- `APOParser`: Preamp, Filter (PK/PEQ/MODAL, LSC/HSC/LS/HS, LP/HP/LPQ/HPQ, NO, AP, BP; "None" and OFF skipped silently),
  GraphicEQ (sorted by frequency), Channel (L/R/1/2/all), Include (relative to the including file, spaces/parens, backslashes
  converted, depth limit 16), `#` comments, decimal commas, BW Oct -> Q, shelf slope form (`HSC 12 dB Fc ...`), UTF-8 (+BOM),
  UTF-16 (BOM LE/BE), CRLF. Every other non-blank line gives a warning (`file:line: ...`). Warnings include REW header lines.
  `parse(text:baseURL:)`: `baseURL` is the Include base directory (if it is an existing file, its parent is used).
- `Response` (`magnitudeDB`, `peak`) as reference (`chain_db`/`peak_db`, 4000 points 5 Hz-22 kHz; HP/LP/notch/AP/BP = 0 dB).
  Extra helpers: `Response.exactMagnitudeDB`, `designBiquad`, `GraphicEQDesigner.{design, merge, interpolateDB}`.
- `GraphicEQDesigner.design`: cepstral min-phase FIR, 32768 taps, FFT 8x, cosine fade on last eighth, vDSP double FFT.
- `EQProcessor`: per channel biquads (vDSP_biquadD, Double) -> gain -> FIR. All gains are folded into one scalar and ALL
  GraphicEQ stages of a channel are merged into one FIR (dB curves summed). Identical FIRs on L/R share one kernel.
  Channel 0 uses `left`, all others `right`.
- FIR: uniformly partitioned (B = 256) convolution with a direct-form head (first 256 taps via vDSP_conv) and FFT tail
  (frequency delay line, overlap-save, real FFT 512). Any `frames` 1...maxFrames (larger is chunked) is handled.
- Headroom: gain = min over left/right of (-headroomDB - peak), only if negative; the MORE NEGATIVE value is applied to all
  channels (keeps stereo balance). Not rounded (reference rounds to 2 decimals).
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
