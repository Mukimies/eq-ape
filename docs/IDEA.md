# Idea: a free "Equalizer APO for Mac" without a virtual driver

Status: this is the original background note, written 2026-11-11 before anything was built; it is kept for context
and parts are outdated (see TAP-FINDINGS.md for what was actually measured). API details below were written from
memory.

## The gap

Equalizer APO is free, parametric, configured by text files and runs unattended. macOS has
nothing equivalent, because it has no official plug-in slot in the audio engine. Existing
options each miss something:

| Option | What it lacks |
|---|---|
| eqMac | Advanced EQ is paid; needs its own virtual driver |
| BlackHole + CamillaDSP (the author's setup before this project) | No GUI, driver install with admin password, two device clocks to keep in sync, manual output switching |
| SoundSource | Paid |

## The approach

Use the system audio tap API that macOS added in 14.2 instead of a virtual output device:

1. The app taps the audio that apps send to the chosen output device.
2. The tap is set to mute the original, so the unprocessed sound is not heard.
3. The app runs the filters and plays the result to the same real device.

What this removes compared with today's setup:

- no driver install and no admin password, only a one-time audio-capture permission prompt
- the real device stays the selected macOS output, so volume keys and output switching keep
  working normally
- capture and playback happen on the same device clock, which should remove the clock-drift
  dropouts seen with BlackHole (to be confirmed)

API names to look up (unverified): `CATapDescription`, `AudioHardwareCreateProcessTap`,
the tap's mute behaviour setting, an aggregate device that includes the tap, and the
`NSAudioCaptureUsageDescription` permission string.

## Requirements

- **Focusrite compatible.** Must work with the Scarlett Solo USB as the first target,
  including being unplugged and replugged while running.
- **Any other output too.** Built-in speakers, headphones, HDMI/DisplayPort monitors, other
  USB interfaces, Bluetooth and AirPlay.
- **Per-device profiles.** Each output device has its own EQ (or none). A room-correction
  file made for the Adam monitors must never be applied to headphones. The profile follows
  the device automatically when the output changes.
- **Equalizer APO text files as the config format.** `Preamp`, `Filter`, `GraphicEQ`,
  `Channel`, `Include`. REW exports load directly. A small Python converter
  (APO to CamillaDSP) written earlier by the author served as the behavioural starting point.
- **Automatic anti-clipping gain**, as `--headroom` does today, plus a live peak and
  clip indicator.
- **Menu bar app**, starts at login, on/off toggle for quick A/B comparison.
- **Free.** macOS 14.2 or later.

## Parts and difficulty

| Part | Difficulty | Notes |
|---|---|---|
| Filter maths (biquads, FIR convolution) | Easy | Already done once in the converter; Accelerate/vDSP has the building blocks |
| APO file parsing | Easy | Re-implement from the documented format |
| Tap, mute and replay on one device | Unknown, the main risk | Needs the proof of concept below |
| Following device changes and per-device profiles | Medium | Plug/unplug, default-output changes |
| Sample-rate changes, sleep/wake, Bluetooth and AirPlay | Medium to hard | Where most of the time will go |
| Latency | Medium | Must stay low enough that video lip-sync is unaffected |
| Menu bar UI | Easy to medium | |
| Distribution | Low effort, some cost | Apple Developer account ($99/year), signing, notarisation |

Rough estimate: a working prototype in one to two weeks, a reliable product in months.

## First step if we pick this up

A proof of concept with no UI: tap the Scarlett's output, mute the original, apply one
peaking filter, play it back to the Scarlett. Success means:

- no doubled or unprocessed sound leaking through
- no dropouts over an hour of playback
- total added delay measured and acceptable for video
- still works after unplugging and replugging the Scarlett, and after sleep

Then repeat on built-in speakers and one Bluetooth device before building anything else.

## Open questions

- Does muting the tapped audio work reliably for every app, including browsers and
  system sounds?
- Does the app's own processed output get re-captured by the tap (feedback), and how is
  that excluded?
- How do taps behave with Bluetooth and AirPlay outputs?
- Is the delay low enough, or does video need compensation?
- Business side: as a paid app this is a small niche (HouseCurve, a comparable audio tool,
  looks like side-project income at best). Free is the realistic framing; the project is released source-available (Apache-2.0 with the Commons Clause).
