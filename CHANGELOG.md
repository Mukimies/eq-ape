# Changelog

All notable changes to EQ Ape are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- `--require-granted`: the GUI starts an engine only when the no-prompt preflights say no permission prompt can appear (audio capture granted; Microphone decided when the device has inputs); otherwise the engine stays off with the state "engine off: …". `--print-permission` prints the preflights and the code-signing identity.
- Instance guard: an EQ Ape process keeps its engine off while another one may be processing the same output device (per-user instance registry and per-device lock, no sockets), so two taps never process the audio twice.
- Development tooling for validating GUI changes (`docs/UI-TESTING.md`): an in-app file-based command channel (`--ui-test-control`), the `App/scripts/uitest` driver with a scripted end-to-end suite and window screenshots, the `App/scripts/uidrive` real-input helper, and a non-blocking CI step for the suite.
- Accessibility identifiers on every interactive control; filter handles and graphic EQ nodes are exposed to VoiceOver as buttons (press selects, increment/decrement changes the gain by 0.5 dB).
- `App/bundle.sh` signs with a local self-signed identity ("EQ Ape Local Dev", or `SIGN_IDENTITY`) when one is available, so the audio-capture permission can survive rebuilds; CI and release builds are unchanged.

### Fixed
- Opening the first-run window could crash the app (AppKit "update constraints" exception from automatic window sizing); found by the UI-test suite.

## [0.1.0-beta.1] - 2026-11-12

First public pre-release (ad-hoc signed, not notarized, Apple Silicon only, macOS 14.2+).

### Added
- Menu bar app that equalizes all system audio on the output device through a Core Audio process tap and a private aggregate device, without a virtual driver.
- Equalizer APO-style config support: `Preamp`, `Filter` (PK, LSC, HSC, LS, HS, LP, HP, LPQ, HPQ, NO, AP, BP), `GraphicEQ`, `Channel`, `Include`, comments, decimal commas, UTF-8 and UTF-16.
- Per-device profiles, following the default output device, live config reload (including included files), sample-rate change handling, anti-clipping headroom.
- Configuration editor: frequency-response graph with draggable filter handles, filter list, live save with backups, undo/redo, A/B bypass, Settings and first-run windows.
- Variable graphic EQ editing, like Equalizer APO's Graphic EQ: an inline node graph on every GraphicEQ row with numbered nodes, a power toggle and a 15-band / 31-band / variable choice; nodes draggable in frequency and gain (variable mode), added and removed, also on the main response graph; "Add Graphic EQ (variable / 15 bands / 31 bands)"; fixed/variable switch with resampling (asks first) in the band-slider sheet. The file keeps Equalizer APO's `GraphicEQ: f g; ...` syntax and only the edited line changes.
- Release tooling: `dist/release.sh`, `dist/make-dmg.sh`, GitHub Actions workflows for CI and releases, and a draft Homebrew cask.

### Changed
- The automatic anti-clipping gain now counts every filter: high-pass, low-pass, notch, all-pass and band-pass (including resonant high/low-pass peaks) and the graphic EQ's real FIR response, searched from 1 Hz to just below Nyquist. Earlier development builds ignored high-pass filters (as an early reference script did) and could spend gain on bass a high-pass removes; for a config with a bass boost and a 30 Hz high-pass the gain went from -10.69 dB to -9.41 dB. It bounds steady tones, not every sample peak (see `docs/EQCORE-NOTES.md`).

### Known issues
See `docs/releases/v0.1.0-beta.1.md`.

[Unreleased]: https://github.com/Mukimies/eq-ape/compare/v0.1.0-beta.1...HEAD
[0.1.0-beta.1]: https://github.com/Mukimies/eq-ape/releases/tag/v0.1.0-beta.1
