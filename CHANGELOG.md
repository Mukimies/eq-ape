# Changelog

All notable changes to EQ Ape are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0-beta.1] - UNRELEASED

First public pre-release (ad-hoc signed, not notarized, Apple Silicon only, macOS 14.2+). The date is to be filled in when it is published.

### Added
- Menu bar app that equalizes all system audio on the output device through a Core Audio process tap and a private aggregate device, without a virtual driver.
- Equalizer APO-style config support: `Preamp`, `Filter` (PK, LSC, HSC, LS, HS, LP, HP, LPQ, HPQ, NO, AP, BP), `GraphicEQ`, `Channel`, `Include`, comments, decimal commas, UTF-8 and UTF-16.
- Per-device profiles, following the default output device, live config reload (including included files), sample-rate change handling, anti-clipping headroom.
- Release tooling: `dist/release.sh`, `dist/make-dmg.sh`, GitHub Actions workflows for CI and releases, and a draft Homebrew cask.

### Known issues
See `docs/releases/v0.1.0-beta.1.md`.

[Unreleased]: https://github.com/Mukimies/eq-ape/compare/v0.1.0-beta.1...HEAD
[0.1.0-beta.1]: https://github.com/Mukimies/eq-ape/releases/tag/v0.1.0-beta.1
