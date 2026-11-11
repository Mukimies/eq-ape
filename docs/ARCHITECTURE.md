# Architecture

EQ Ape is a menu bar app for macOS 14.2 or later (Apple Silicon only). It equalizes the system audio going to an output
device without a virtual audio driver, using Core Audio process taps. Configuration uses Equalizer APO-style text files.

## Layout

| Directory | Contents |
|---|---|
| `EQCore/` | Swift package, pure DSP and config parsing, no audio I/O. Library `EQCore` plus tests. |
| `poc-tap/` | Swift package, command-line tool `eqtap`: the proof of concept of tap, mute and replay on one device. |
| `App/` | The menu bar app (`EQ Ape.app`), combining the tap engine with EQCore. Built with `App/bundle.sh`. See `docs/APP-NOTES.md`. |
| `dist/` | DMG tooling, draft release workflow and draft Homebrew cask. See `docs/DISTRIBUTION.md`. |
| `docs/` | Background and findings: `TAP-FINDINGS.md` (tap measurements), `EQCORE-NOTES.md`, `APO-PARITY.md`, `DISTRIBUTION.md`, `IDEA.md`. |

## How the audio path works

1. Create a process tap of the chosen output device that excludes EQ Ape's own process (this prevents feedback) and
   mutes the original sound only while the tap is being read.
2. Put the tap and the real device into one private aggregate device whose clock is the real device.
3. One IOProc on the aggregate reads the tap, runs the EQ in place and writes the result to the device's output,
   all in the same IO cycle. There is no ring buffer, no resampling and no drift correction.
4. Tap and aggregate are private objects. If the process dies, coreaudiod removes them and the original audio is
   audible again.

Measured details (API sequence, latency of about 23-24 ms, permission behaviour, crash safety) are in `docs/TAP-FINDINGS.md`.

## EQCore API contract

```swift
public enum BiquadKind { case peaking, lowShelf, highShelf, lowPass, highPass, notch, allPass, bandPass }
public struct BiquadSpec: Equatable, Sendable { public var kind: BiquadKind; public var freq: Double; public var gainDB: Double; public var q: Double?; public var slopeDBPerOct: Double?; /* plus bandwidthOct: Double? */ }
public enum Stage: Equatable, Sendable { case gain(dB: Double); case biquad(BiquadSpec); case graphicEQ(points: [GraphicEQPoint]) }
public struct GraphicEQPoint: Equatable, Sendable { public var freq: Double; public var gainDB: Double }
public struct EQConfig: Equatable, Sendable { public var left: [Stage]; public var right: [Stage] }   // stereo; channel 0 uses left, all others right
public struct ParseResult { public var config: EQConfig; public var warnings: [String] }
public enum APOParser { public static func parse(fileURL: URL) throws -> ParseResult; public static func parse(text: String, baseURL: URL?) -> ParseResult }
public enum Response { public static func magnitudeDB(stages: [Stage], freq: Double, sampleRate: Double) -> Double; public static func peak(stages: [Stage], sampleRate: Double) -> (dB: Double, freq: Double) }
public final class EQProcessor {            // one instance per stream; process() is real-time safe (no allocation, no locks)
    public init(config: EQConfig, sampleRate: Double, channels: Int, headroomDB: Double?, maxFrames: Int)
    public func process(_ channelData: UnsafePointer<UnsafeMutablePointer<Float>>, frames: Int)   // non-interleaved, in place
    public var peakLinear: [Float] { get }   // per channel, since last read-and-reset
    public var clippedSamples: UInt64 { get }
    public var appliedHeadroomGainDB: Double { get }
}
```

The listing above is abridged from the contract; the source in `EQCore/Sources/EQCore/` is authoritative.

Semantics: the config syntax is Equalizer APO's (`Preamp`, `Filter` with PK, LSC, HSC, LS, HS, LP, HP, LPQ, HPQ, NO, AP, BP,
`GraphicEQ`, `Channel`, `Include`; `#` comments; OFF filters skipped). Biquads follow the RBJ cookbook. GraphicEQ becomes a
minimum-phase FIR, linear in dB over log frequency, held flat outside the end points. Behaviour was matched to Equalizer
APO's documented behaviour and re-implemented; no code was copied (see `docs/APO-PARITY.md`). `EQCORE-NOTES.md` describes the
DSP internals.

## Contributor warning: unanswered permission prompts block all audio

The first `AudioDeviceStart` on an aggregate that contains a tap makes coreaudiod ask macOS for the audio-capture
permission (TCC `kTCCServiceAudioCapture`) and **blocks until the prompt is answered**. While a prompt is pending, no
process on the Mac can start new audio, because coreaudiod's later permission checks queue behind it; already-running audio
keeps playing. This was observed during development (`docs/TAP-FINDINGS.md`, "Incident"). Therefore, when working on this code:

- Start audio off the main thread with a timeout, and never raise a second, different permission request while one is pending.
- Do not include the device's input streams in the aggregate: that triggers a second (Microphone) permission check.
- Test with care when a new build or identity will raise a new prompt: be at the machine to answer it. Anything started as
  a child of a terminal that already holds the audio-capture permission inherits it, so use the command-line `eqtap` or the
  app's headless mode from such a terminal for runtime testing.
- Never ship objects with the `public` flag: public taps and aggregates outlive a crashed owner and could leave audio muted.

## Testing notes

- `swift test` in `EQCore/` covers parsing, filter responses, the FIR engine and Equalizer APO parity.
- Verify Apple API details against the SDK headers (`xcrun --show-sdk-path`; for example `CoreAudio/AudioHardwareTapping.h`
  and `CATapDescription.h`) rather than memory.
- Test devices used so far: Scarlett Solo USB, MacBook Pro Speakers, with BlackHole 2ch and Adam monitors in the author's
  setup. Bluetooth, AirPlay and HDMI are untested.
