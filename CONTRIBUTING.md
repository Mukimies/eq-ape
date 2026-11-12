# Contributing to EQ Ape

Bug reports, test results on other devices, and pull requests are welcome.

## Build and test

Requires an Apple Silicon Mac, macOS 14.2+, and Xcode 26 / Swift 6.x (the App package needs swift-tools 6.0).

```sh
cd EQCore && swift test     # DSP and parser tests
cd App && swift test        # app logic tests (no audio is started)
cd App && ./bundle.sh       # builds "App/build/EQ Ape.app" (arm64, ad-hoc signed); does not launch it
dist/release.sh 0.1.0-beta.1   # tests + bundle + DMG in dist/out/ (maintainers)
```

Tests that need a real config file skip themselves when `EQAPE_REAL_CONFIG` is unset; that is expected.

## Warning: unanswered permission prompts block all audio

The first `AudioDeviceStart` on an aggregate device with a tap makes coreaudiod ask macOS for the audio-capture permission and blocks until the prompt is answered. While a prompt is pending, no process on the Mac can start new audio. When you run a build that may raise a new prompt (a new signature, a new bundle), be at the machine and answer it. Start audio off the main thread with a timeout, never raise a second request while one is pending, never put the device's input streams in the aggregate, and never use public taps or aggregates. For runtime testing, run the command-line tools or the app's headless mode from a terminal that already holds the permission. Details: `docs/ARCHITECTURE.md`, `docs/TAP-FINDINGS.md`.

## Licence of contributions

EQ Ape is Apache-2.0 with the Commons Clause (see `LICENSE`); it is source-available, not open source. By submitting a contribution you agree it is licensed under the same terms.

## No GPL code

Do not copy or closely translate code from GPL-licensed projects, in particular Equalizer APO. EQ Ape only reads its config format and re-implements documented behaviour (`docs/APO-PARITY.md`). Do not add dependencies whose licences are incompatible with these terms.

## Pull requests

Keep changes focused, add or update tests where there are tests for the area, and note in the PR what you did and did not verify (for example which output device).
