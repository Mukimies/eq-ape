# Equalizer APO parity audit

Audit of EQCore against Equalizer APO's actual source and wiki. Date: 2026-11-11.

## Sources consulted
- Source: `git clone https://git.code.sf.net/p/equalizerapo/code` (SourceForge project "equalizerapo"), HEAD `bbfcc3e5` (2025-11-28).
  Files read: `filters/BiQuad.cpp`, `BiQuadFilter.cpp`, `BiQuadFilterFactory.cpp`, `GraphicEQFilter.cpp`, `GraphicEQFilterFactory.cpp`,
  `IIRFilterFactory.cpp`, `PreampFilterFactory.cpp`, `ChannelFilter.cpp`, `CopyFilter*.cpp`, `DelayFilterFactory.cpp`,
  `IncludeFilterFactory.cpp`, `helpers/GainIterator.cpp`, `helpers/ChannelHelper.cpp`, `FilterEngine.cpp` (`loadConfigFile`, `addFilters`),
  and the wiki page `Wiki/Configuration reference.txt` from the same checkout.
- No code was copied; behaviour was described and re-implemented, and tests re-derive expected values independently.

## Licence
**GNU General Public License version 2 or (at your option) any later version (GPL-2.0-or-later).**
Evidence: `License.txt` is the GPLv2 text ("Version 2, June 1991"); every source header (e.g. `filters/BiQuad.cpp`,
`EqualizerAPO.licenseheader`) reads "either version 2 of the License, or (at your option) any later version", copyright Jonas Thedering.
Consequence: copying its code into a project would require GPL-2.0-or-later (compatible with GPLv3 and GPLv2); re-implementing
behaviour from the documented semantics does not. EQCore contains no copied code.

## Feature table

Status: matches / differs / missing. "Fixed" = changed in this audit.

| Feature | Equalizer APO | EQCore (now) | Status |
|---|---|---|---|
| PK / PEQ / Modal | RBJ peaking, A=10^(g/40). Gain and Q-or-BW required, else the filter is dropped (`BiQuadFilterFactory`). `Modal` extra "T60 target" ignored | same, incl. dropping filters without Q/BW or Gain (with a warning) | Fixed (was: default Q 0.707) |
| LP/HP/LPQ/HPQ | RBJ, Q default `M_SQRT1_2`, gain ignored; LP==LPQ, HP==HPQ | same, default Q now exactly 1/sqrt(2) | Fixed (was 0.7071) |
| BP | RBJ constant 0 dB peak (b0=alpha), default Q 1/sqrt(2) | same | matches |
| NO | RBJ notch, default Q 30, gain ignored | same | matches |
| AP | RBJ all-pass, Q or BW required | same, dropped without Q/BW | Fixed |
| BW Oct (non-shelf) | `alpha = sin w * sinh(ln2/2 * BW * w/sin w)`, "BW Oct" literal required, overrides a Q on the same line | new additive field `BiquadSpec.bandwidthOct`, same formula | Fixed (was: Q = sqrt(2^BW)/(2^BW-1), the analog approximation, and Q beat BW) |
| BW on shelves | ignored | ignored | Fixed (was converted to Q) |
| LSC/HSC | centre frequency, `alpha = sn/(2Q)` for Q, `alpha = sn/2*sqrt((A+1/A)(1/S-1)+2)` for slope, S = x dB / 12 | same | matches |
| Shelf default | S = 0.9 (= 10.8 dB/oct), "found by experimentation with RoomEQWizard", not corner-shifted | slopeDBPerOct 10.8; `designBiquad` default also 10.8 | Fixed (was 12 dB/oct, S = 1) |
| LS/HS (corner) with Q or slope (`LS 6dB`, `LS 12 dB`, `LS ... Q`) | `BiQuadFilter::initialize`: centre = fc * 10^(abs(gain)/80/S) for LS, fc / same for HS; for Q, S = 1/((1/Q^2-2)/(A+1/A)+1). `LS 6dB`/`LS 12dB` are covered by the generic "x dB" parse | parser emits the converted centre frequency in `BiquadSpec.freq`, same formulas; no warning | Fixed (was: treated corner as centre, with a warning) |
| LS/HS without Q/slope | S=0.9 centre frequency = Fc (no conversion) | same | matches (previous warning was wrong, removed) |
| Slope vs Q on one shelf line | slope overrides Q | same | Fixed |
| Fc parsing | `\s+Fc\s*[-+0-9.eE nbsp]+\s*H\s*z`; every `,` becomes `.`; NBSP removed; if length >= 5, no `e`, and 4th-last char is `.` the value is x1000 (REW thousands separator, `getFreq`) | same quirk implemented | Fixed |
| Case sensitivity | Command names (`Preamp`, `Filter`, `GraphicEQ`, `Channel`, `Include`), `ON`, filter type names (`Modal` only in that spelling), and `Fc/Gain/Q/BW Oct/Hz/dB` are all case-sensitive (std::wregex without icase, map lookup); other text is silently ignored | same strictness, with a warning that says why | Fixed (was case-insensitive) |
| ON / OFF | Only `ON` matches; `OFF` lines (and "None") silently dropped | same (OFF silent) | matches |
| Filter numbering | `Filter N:` any text after "Filter" (prefix match) is accepted, N unused | same | matches |
| IIR (`ON IIR Order n Coefficients ...`) | generic IIR, needs rate-specific coefficients | warned as unsupported | missing |
| Preamp | `sscanf(" %lf dB")`: returns 1 after the number, so the unit is not checked (`Preamp: -6 db` in the wiki works, `Preamp: -6` also); several preamps add in dB | number only, case-insensitive unit not required; decimal comma; `.5` allowed | Fixed (was: required "dB", found number anywhere in the line, `.5` gave 5) |
| GraphicEQ interpolation | `GainIterator`: linear in dB over ln(freq); flat below the first and above the last node; nodes sorted | same | matches |
| GraphicEQ parsing | all maximal runs of `[-+0-9.eE]` are paired (freq, gain); `;`, spaces, tabs, text are only separators; commas become `.` only if the string has no `.` | same tokenisation | Fixed (was: required `;` between pairs and exactly two whitespace-separated fields) |
| GraphicEQ filter | `GraphicEQFilter::initializeFilters`: minimum phase via cepstrum (`mps`), 16384 taps, spectrum sampled on a 32768-point grid, magnitude floor -100 dB, half-Hann taper over the whole length | minimum phase via cepstrum, 32768 taps, FFT 8x, cosine fade over the last eighth, no -100 dB floor | differs, benign: longer FIR, finer low-frequency resolution, effectively the same response (not changed; the taper in APO changes the response < 0.01 dB for bass-scale features) |
| GraphicEQ with 0 or 1 node | accepted (1 node = constant gain) | warning, not converted | differs, benign; left (existing test encodes the warning) |
| Channel names | `L R C LFE RL RR RC SL SR`, numbers (wcstol of leading digits, counted from 1), `ALL`, legacy `SUB`; words upper-cased, split on space; unknown word is ignored and the others still apply; a Channel line with no valid word selects nothing; **channel selection is saved on entering an Include and restored on leaving it** (`loadConfigFile`) | stereo: L, R, 1, 2, ALL (any case); other names warned; selection now restored after Include | Fixed (include restore) |
| Channel on non-stereo devices | names depend on the device channel mask | stereo model only (left = ch 0, right = rest) | differs, by design (see ARCHITECTURE.md) |
| Include | relative to the directory of the including file; leading whitespace trimmed; recursion limit 100; missing file is logged and skipped | same; limit raised 16 -> 100; also strips optional quotes and converts `\` to `/` (macOS leniency) | Fixed (limit) |
| Comments | none as such: the line is split at the first `:`; no colon, or an unknown key (`# Filter 1`) = silently ignored | `#` lines skipped; unknown lines warned (REW header etc.) | matches (warnings are an EQCore addition) |
| Unknown lines/commands | silently ignored | ignored with a warning | matches |
| Decimal separator | locale-independent: `,` -> `.` in Filter/Preamp/Delay values | same | matches |
| Encoding | UTF-8, falls back to ANSI code page if U+FFFD appears | UTF-8 (+BOM), UTF-16 with BOM | differs, benign |
| Response display | n/a (the real filter chain is applied) | `Response.magnitudeDB`/`peak` deliberately count only gain/PK/shelf/GraphicEQ ("reference" semantics of the Python converter), `exactMagnitudeDB` counts everything | differs by design; see gaps |

## Commands EQCore does not implement
| Command | What it does | First macOS release? |
|---|---|---|
| `Device:` | Applies following lines only if the output device matches the patterns (words in "device connection GUID", `;` = OR) | Maybe later: per-device profiles already exist in the app; low priority |
| `Stage:` | Selects pre-mix / post-mix (/capture) APO stage | No (no equivalent on macOS) |
| `Copy:` | Channel mixing: `L=L+0.5*R`, dB factors, constants (a `0` or a value with `.` is a constant) | Gap; needs a channel-matrix stage in the model (cannot be expressed in left/right stage lists). Medium priority for stereo-only: swap/mono-sum/balance |
| `Delay:` | Delays selected channels by `n ms` or `n samples` (decimal comma ok, unit lower-cased) | Gap; needs a new `Stage` case, which would break exhaustive switches in the app, so it was not added without coordination. Medium priority (speaker time alignment) |
| `Convolution:` | Convolves with an impulse response (libsndfile formats; channels assigned round-robin) | Gap; high value for room correction users, a partitioned FIR engine already exists in EQCore (`PartitionedFIR`). Needs a WAV/AIFF/FLAC reader (AVAudioFile) |
| `Eval:` / `If:` / `ElseIf:` / `Else:` / `EndIf:` / inline `` `expr` `` | Expression language (variables, sampleRate, deviceName, ...) and conditional blocks | No. Lines inside `If:` blocks are currently applied unconditionally, which is wrong when a config uses `If: sampleRate == ...`. Cheap partial mitigation: warn on `If:` (done by the generic unknown-line warning) |
| `LoudnessCorrection:` | Volume-dependent loudness (ISO 226) filter reading the Windows volume | No (needs system volume model) |
| `VSTPlugin:` | Loads a VST2 plugin | No |
| `Filter: ON IIR ...` | Arbitrary-order IIR with explicit coefficients | Low priority; easy to add as an additive stage later |

## Prioritised gaps (remaining)
1. `If:/EndIf:` blocks: contents are applied unconditionally (wrong for rate-dependent configs). Option: evaluate the common `sampleRate == N` / `inputChannelCount == N` forms, or skip blocks and warn.
2. `Copy:` and `Delay:`: need public-model changes (channel matrix stage; delay stage). Coordinate with the app first.
3. `Convolution:` using the existing partitioned convolver.
4. `Device:` (profile selection by output device pattern).
5. `Response.magnitudeDB`/`peak` ignore LP/HP/NO/AP/BP, so UIs that plot the response or compute headroom from `peak` ignore the user's HPQ stages (they only ever lower the peak, so headroom stays safe; the plot is wrong at low frequencies). Use `exactMagnitudeDB` for plotting. Not changed because the API contract pins the reference semantics.
6. GraphicEQ FIR: optionally match APO's 16384 taps/half-Hann taper (difference is negligible).
7. IIR filter type; GraphicEQ with a single node.
8. ANSI fallback for non-UTF-8 files.

## Changes made in EQCore (see EQCORE-NOTES.md)
Additive API: `BiquadSpec.bandwidthOct` (default nil, last init parameter). No signature or semantics change for existing fields except
documented parser output changes (default shelf slope 10.8, shelf corner frequencies converted to centre frequencies in the parser).
Tests changed (each encodes behaviour disproved by the source): `testFilterTypes` (HSC default slope 12 -> 10.8; LS warning count 1 -> 0;
LP/HP default Q 0.7071 -> 1/sqrt(2)); `testDecimalCommaAndBandwidth` (BW Oct no longer converted to Q, now `bandwidthOct`).
New tests: `ParityTests.swift` (10 tests).
User's real config: parsed stages are identical before and after; response unchanged (see EQCORE-NOTES.md).
