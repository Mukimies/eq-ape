# EQ Ape

EQ Ape is a menu bar equalizer for macOS that processes all system audio going to your output device, without installing a virtual audio driver. It reads Equalizer APO-style configuration files, so existing parametric EQ and room-correction text files (including REW exports) can be loaded directly.

## Status

Early beta, built in one evening. What has and has not been checked:

- **Measured and tested:** the tap engine (tap, aggregate device, in-place processing, replay to the same device) was measured on a Scarlett Solo USB and on MacBook Pro Speakers: real audio, processing applied, no overloads or timestamp discontinuities, about 23-24 ms added delay. The DSP and config parser are covered by automated tests (`EQCore`, including a parity audit against Equalizer APO's documented behaviour).
- **Needs listening confirmation on each setup:** that the original, unprocessed sound is actually muted. There is no measurable proxy for this, so it has only been designed for (a muted-while-tapped tap), not confirmed by ear on every device.
- **Tested headless only:** the app logic (per-device profiles, following the default output, live config reload, sample-rate change, a 5-minute soak, recovery after `kill -9`) was exercised through the app's headless mode. See `docs/APP-NOTES.md` for the numbers.
- **Not tested at all:** the menu bar GUI has never been launched, and the app's own permission prompt has never been seen.
- **Unverified:** Bluetooth, AirPlay and HDMI outputs; unplug/replug and sleep/wake; runs longer than five minutes; whether the audio-capture permission survives updates of an unsigned build.

See `docs/APP-NOTES.md` for app-level status. See `docs/TAP-FINDINGS.md` for the full list of what was and was not verified for the tap engine.

## Requirements

- macOS 14.2 or later
- Apple Silicon (arm64). There is no Intel or universal build.

## How it works

1. EQ Ape creates a Core Audio process tap of the chosen output device (excluding its own process) and mutes the original sound while the tap is read.
2. It applies your EQ to the tapped audio.
3. It plays the result to the same real device.

There is no virtual driver and no admin password: your real device stays the selected macOS output, so volume keys and output switching keep working. Capture and playback share the device's clock. The added delay measured in the proof of concept is about 23 ms. More detail is in `docs/ARCHITECTURE.md`.

## Permission and privacy

macOS asks for the **audio capture** permission the first time EQ Ape starts processing. It is needed because a process tap is the only way, short of a virtual driver, to receive the audio other apps send to an output device. It is not a microphone permission and EQ Ape does not record anything.

Audio is processed in memory only. It is not written to disk and not sent anywhere. The app makes no network connections: a search of the source (`App/`, `EQCore/`, `poc-tap/`) found no use of URLSession, the Network framework or sockets, and no update checker. The only external things it opens are local files and folders (your config file and its settings folder) in the default editor or Finder. You can audit this yourself in the source.

Warning for contributors and testers: an unanswered macOS permission prompt can stall new audio for every app on the Mac until it is answered. See `docs/ARCHITECTURE.md`.

## Equalizer APO config compatibility

Supported (the config files use Equalizer APO's format):

- `Preamp`
- `Filter` types PK (also PEQ, Modal), LSC, HSC, LS, HS, LP, HP, LPQ, HPQ, NO, AP, BP, with Equalizer APO's defaults (for example shelf slope, default Q) and `BW Oct`
- `GraphicEQ`
- `Channel` (stereo: L, R, 1, 2, ALL)
- `Include`
- `#` comments, decimal commas, UTF-8 and UTF-16 files

Not supported (lines using these are ignored with a warning): `Device:`, `Stage:`, `Copy:`, `Delay:`, `Convolution:`, `Eval:`, `If:`/`ElseIf:`/`Else:`/`EndIf:` (the lines inside an `If:` block are currently applied unconditionally), `LoudnessCorrection:`, `VSTPlugin:`, `Filter: ON IIR ...`. Channel handling assumes a stereo model. Details are in `docs/APO-PARITY.md`.

EQ Ape is not affiliated with, endorsed by or sponsored by the Equalizer APO project, and no code from Equalizer APO is used. Equalizer APO is a name of its respective owners.

## Installing

Download the DMG from the GitHub Releases page of this repository once a release is available, open it and drag EQ Ape to Applications. Verify the download with the `.sha256` file: `shasum -a 256 -c EQ-Ape-<version>.dmg.sha256`.

The first release is expected to be **not notarized** (subject to change). On current macOS (15 and later), Control-click > Open no longer bypasses Gatekeeper. Instead:

1. Double-click EQ Ape. macOS shows an alert that it cannot verify the app. Close it (do not move the app to the Trash).
2. Open System Settings > Privacy & Security, scroll to the Security section and click **Open Anyway** next to the EQ Ape message, then confirm.

Alternatively, `xattr -dr com.apple.quarantine "/Applications/EQ Ape.app"` removes the quarantine flag. The exact wording varies between macOS versions. An unsigned build will probably need the audio-capture permission granted again after each update. Building from source yourself avoids the quarantine step. See `docs/DISTRIBUTION.md`.

## Building from source

Requires a recent Xcode or Swift toolchain on an Apple Silicon Mac.

```sh
cd EQCore && swift test        # DSP and parser tests
cd poc-tap && ./build.sh       # command-line proof of concept, builds build/eqtap.app
cd App && ./bundle.sh          # builds "App/build/EQ Ape.app" (arm64, ad-hoc signed, not launched by the script)
```

For app-level instructions and notes see `docs/APP-NOTES.md`. Building does not start audio, but running the app or `eqtap` will trigger the audio-capture permission prompt.

## Licence

EQ Ape is released under Apache-2.0 with the Commons Clause (see `LICENSE`). You may use it for free, including at work, and read, modify and share it; you may not sell it, or a product or service whose value derives substantially from it. Because of the Commons Clause this is **source-available** software, not open source as the term is defined by the Open Source Initiative.

## Contributing

Contributions are welcome: bug reports (please include macOS version, output device and what the permission state was), test results on other devices, and pull requests. By contributing you agree that your contribution is licensed under the same terms as the project (Apache-2.0 with the Commons Clause). Do not copy code from GPL-licensed projects such as Equalizer APO.
