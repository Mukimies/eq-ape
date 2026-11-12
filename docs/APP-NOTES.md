# EQ Ape app notes (phase 2, `App/`)

Date 2026-11-11. macOS 26.6.2, Apple Silicon, Swift 6.3.3. EQ Ape is Apple Silicon only (arm64).
Working names: user-visible name **EQ Ape**, executable and identifiers `EQApe`, bundle id placeholder
`org.eqape.EQApe`, settings in `~/Library/Application Support/EQ Ape/settings.json`.

**Status:** the package builds and its unit tests pass (13 at phase 2, 20 since the editor update, 26 since the GraphicEQ node editor). All five runtime tests below passed in headless mode on the
real hardware, plus an extra sample-rate test. The bundle builds and passes verification. The release bundle was
never launched with its engine, on purpose (permission-prompt hazard). The GUI was only launched with `--no-engine`
(editor update, 2026-11-12: 20 App tests; see `docs/EDITOR-NOTES.md`). The app's own permission prompt and muting by
ear are unverified.

## Architecture

```
App/ (Swift package, swift-tools 6.0, Swift 5 language mode, macOS 14.2+, depends on ../EQCore by path)
  Sources/TapAtomics   C11 atomics: RTStats (counters, float peaks) + RTSlot (lock-free pointer hand-over)
  Sources/TapKit       tap engine adapted from poc-tap (poc-tap itself untouched)
     HAL.swift           C HAL property helpers (public)
     TapEngine.swift     tap -> private aggregate -> one IOProc (capture, process, play in one cycle)
     EngineStats.swift   EngineStats (shared across engine rebuilds), ProcessorSlot, ProcessorBox
     Permission.swift    read-only TCC preflight (private TCCAccessPreflight; never prompts)
  Sources/EQApeCore    app logic without UI (headless-testable)
     Settings.swift      Settings / DeviceProfile (Codable, tolerant decoding), SettingsStore (atomic JSON)
     Decision.swift      EngineState + pure profile-selection rules
     ConfigLoader.swift  APOParser + fallback rules + IncludeScanner (watch list)
     FileWatcher.swift   stat-polling watcher (0.25 s, settle 1 tick)
     TapController.swift control-queue state machine: device following, rebuilds, reloads, swaps
  Sources/EQApe        executable: SwiftUI MenuBarExtra app + headless/CLI mode (same binary)
  Tests/EQApeCoreTests 20 tests (settings, profile rules, fallbacks, includes, file watching, slot, controller, editor)
  Resources/           Info.plist, EQApe.entitlements, make-icon.swift
  bundle.sh            release arm64 build -> build/EQ Ape.app, ad-hoc signed (hardened runtime), verified
  scripts/runtime-test.sh  guarded runtime tests (always restore BlackHole + CamillaDSP)
```

**Engine (TapKit):** the same proven design as poc-tap. It creates a `CATapDescription` that excludes our own HAL
process object, for stream 0 of the device, with `mutedWhenTapped` and `isPrivate`. The private aggregate uses the
real device as main sub-device (clock and output) and the tap as input. One IOProc deinterleaves the tap buffer,
runs the slot's processor in place, interleaves to the outputs, and counts peaks, clipped samples (|x| >= 1),
discontinuities and callbacks. `AudioDeviceStart` runs on a worker thread with a timeout (default 5 s).
Teardown order: stop, destroy IOProc, aggregate, tap.

**Glitch-free processor swap:** `ProcessorSlot` (C `RTSlot`). On each cycle the IO thread does
`busy=1; p=load(ptr); process; busy=0`: seq_cst atomics, no allocation, no locks, no retain/release. The control
queue builds the new `EQProcessor` off-thread, `exchange`s the pointer, waits until `busy==0` has been seen once
(Dekker argument: any later cycle loads the new pointer), and then releases the old processor on the control
queue. If that wait ever exceeds 2 s, the old processor is leaked instead of being freed while possibly in use.
The box carries its channel count, and the IO block only uses it if it matches the tap. Measured: 13–17 ms to
build and swap the real config.

**Controller (EQApeCore):** everything runs on one serial control queue (`EQApe.control`), never on the audio
thread or the main thread.
- Inputs that trigger a debounced (0.25 s) `reconcile()`:
  - system default-output changes and device-list changes;
  - on the current device: IsAlive, nominal rate, output stream configuration, the streams list, and each output
    stream's virtual format;
  - the aggregate's own "sample rate changed" and "lost sub-device" signals;
  - `NSWorkspace` will-sleep (tear down) and did-wake (forced rebuild after 1 s);
  - a watchdog: no IO callbacks for 3 s means a forced rebuild;
  - config file changes.
- `reconcile()` applies `Decision.decide` (global on/off, device UID, profile, enabled flag, config path). Anything
  other than "process" tears the engine down and leaves the device completely untouched: no tap, no mute.
- The config is loaded with `APOParser`. A missing file, an unreadable file or a parse with no stages gives
  **bypassed = untouched** (the engine is torn down, never silence). Watching continues, so fixing the file brings
  the EQ back. Warnings are kept for display.
- An engine rebuild happens only when the key (device UID + rate/channels/format signature) changes, or when one is
  forced. Otherwise a config or headroom change only swaps the processor; the tap is not rebuilt.
- If `prepare` or `start` fails, it retries with backoff (1, 2, 4 … 30 s). If start **times out** (likely a pending
  permission prompt), it sets `startBlocked`, never retries automatically, and the user's "Reload" clears it.
- Anti-clipping: `DeviceProfile.headroomEnabled` / `headroomDB` (default on, 0.5 dB) is passed to `EQProcessor` as
  `headroomDB`. The applied gain is exposed in `Status.appliedGainDB`. Peak and clip statistics come from
  `takeMeter()`.
- Global off (`Settings.enabled = false`) tears the engine down: audio untouched.

**Settings file** (`~/Library/Application Support/EQ Ape/settings.json`, pretty JSON, slashes not escaped):
```json
{ "enabled": true, "version": 1,
  "profiles": { "<device UID>": { "deviceName": "Scarlett Solo USB", "enabled": true,
      "configPath": "/Users/.../config.txt", "headroomEnabled": true, "headroomDB": 0.5 } } }
```
A corrupt file is not overwritten at load. An error is shown, and only the next explicit change saves.

**Live reload:** stat polling (every 0.25 s) of the config and every file it Includes, recursively. The watch list
is rebuilt on every load, and missing files are watched too. A change fires after the files have stayed unchanged
for one more poll. This survives editors that save by writing a new file and renaming it over the original. Measured
edit-to-new-EQ time: **0.34–0.36 s**.
Equalizer APO was consulted only as a behavioural reference: it is **GPLv2** (SourceForge project page), it reloads
automatically when files in its config directory change, and it follows includes. No code was copied or read in
detail; the watcher is an independent re-implementation.

**GUI (`EQApe` without arguments):** SwiftUI `MenuBarExtra` (`.menu` style), `LSUIElement` plus the `.accessory`
activation policy. Updated 2026-11-12; details in `docs/EDITOR-NOTES.md`. The menu has:
- the on/off toggle;
- "device: state";
- "Bypass (A/B)";
- "Reload" (only in an error state such as "audio start blocked");
- "Open Editor…";
- "Settings…";
- "Quit EQ Ape".

The config editor window shows the response graph with draggable handles, the filter list, the GraphicEQ band editor,
live saving with backups, undo, and a status strip with meters, the anti-clipping gain, A/B bypass and warnings. The
Settings window lists the device profiles (config, enabled, anti-clipping and headroom), Launch at Login
(`SMAppService`, only when toggled) and the permission explanation with a link to System Settings. A first-run window
explains the permission prompt before the engine first starts (only when there are no profiles yet). settings.json is
now re-read when it changes on disk.

GUI launch flags: `--no-engine` (no engine, taps or device I/O; settings read-only unless `--settings`),
`--editor <file>`, `--settings <file>`, `--backup-dir <dir>`, `--render-snapshots <dir>`, `--smoke-test`.
`BUILD_DIR=build-dev ./bundle.sh` builds into `App/build-dev/`.

## Build and run

```sh
cd ~/code/standalone-mac-eq/App
swift build                 # debug
swift test                  # 20 tests
./bundle.sh                 # release arm64 -> build/EQ Ape.app, ad-hoc signed + verified (never launched)
B=.build/arm64-apple-macosx/release/EQApe
$B --list | --get-default | --set-default "<name>" | --set-rate "<name>" <Hz> | --taps
$B --probe --device "<name>"          # tap + aggregate without IO (no permission needed), prints layout
$B --headless --device "Scarlett Solo USB" --config /path/to/config.txt [--seconds N] [--headroom 0.5|--no-headroom] [--bypass]
$B --headless --follow-default [--settings file.json] [--seconds N]
scripts/runtime-test.sh real|reload|follow|soak|rate|kill9    # guarded; always restores the audio chain
```
Headless mode prints one status line per second:
`[t] in <peak> out <peak> dBFS | clip <n> | cb <callbacks> | ovl <overloads> | disc <n> | gain <dB> | <device> | <state>`.
It refuses to start IO unless the TCC preflight for the responsible process says "granted" (`--allow-prompt`
overrides). Run from Terminal, the responsible process is Terminal, which has the permission.

**Bundle:**
- Info.plist: `CFBundleIdentifier org.eqape.EQApe`, name / display name "EQ Ape", `CFBundleExecutable EQApe`,
  version 0.1.0 (1), `LSUIElement` true, `LSMinimumSystemVersion` 14.2, `LSArchitecturePriority` [arm64],
  `NSAudioCaptureUsageDescription`, and a generated icon (`AppIcon.icns`).
- Signature: ad hoc, `--options runtime`, entitlements `com.apple.security.device.audio-input`.
- Verified: `plutil -lint` OK; `codesign --verify --deep --strict`: "valid on disk, satisfies its Designated
  Requirement"; flags `adhoc,runtime`; thin arm64.
- **Entitlement uncertainty:** the CoreAudio SDK headers say nothing about entitlements for process taps. Apple's
  entitlement reference describes `com.apple.security.device.audio-input` as covering "audio input using Core
  Audio" under the hardened runtime. One third-party project (catap) says taps need no extra entitlement. It is
  included as the conservative choice. Confirm with the first Developer ID build. The app is not sandboxed.

## Runtime test results (headless mode, from this terminal)

Every test used the guarded script: CamillaDSP stopped, default output set to the device under test, a quiet
`afplay -v 0.05 Glass.aiff` looped, then everything restored. Glass is -40.1 dBFS peak at the tap. All runs:
48 kHz, 2 ch, 512-frame IO buffer, about 94 callbacks/s.

| # | Test | Result |
|---|---|---|
| 1 | Scarlett + real `config.txt`, 35 s | Input -40.1 dBFS, output **-51.6 dBFS** (-11.5 dB). Applied anti-clip gain **-10.69 dB** + preamp -1 dB = -11.69 dB expected above 100 Hz. (Measured with the old reference peak search; since 2026-11-12 the gain for this config is -9.41 dB, see EQCORE-NOTES "Anti-clipping". Not re-run with audio.) **0 overloads, 0 clipped, 0 discontinuities**, 3223 callbacks, 6 parser warnings (REW header lines). Engine start 555 ms. |
| 2 | Live reload of a copy (`App/.scratch/live`, `--no-headroom`) | Baseline out -40.9 dBFS. Appending `Preamp: -6 dB` gave a reload 0.34 s after the edit and out **-46.9** (-6.0 dB). Changing the *included* file's preamp from -1 to -13 dB gave a reload 0.35 s later and out **-58.9** (another -12.0 dB). Restoring both brought out back to -40.9. Engine rebuilds 1 (never restarted), reloads 4, 0 overloads, 0 discontinuities. |
| 3 | `--follow-default`, profiles for Scarlett + MacBook Pro Speakers | Scarlett to Speakers: engine moved (event to running took 0.4 s, start 53 ms), processing at -51.6 out. Speakers to Scarlett: moved (start 338 ms), processing. To HDMI monitor (no profile): **engine released**, state "no profile", callbacks stop, nothing tapped. Back to Scarlett: re-engaged (start 257 ms). 4 rebuilds, 0 overloads, 0 clipped. |
| 4 | Soak, Scarlett + real config, 300 s | **28068 callbacks, 0 overloads, 0 discontinuities, 0 clipped.** All 124 seconds with sound: out -51.6 dBFS (one second -51.7). CPU: 8.59 s of CPU over 286 s = **about 3.0 % of one core** on average (`ps -o %cpu` samples every 15 s showed 0.0–0.3 %, a decaying average). RSS **34.6 MB, flat** (34608–34656 kB, no growth). |
| 5 | `kill -9` during processing | Afterwards **0 taps and 0 aggregates visible**, and `afplay -t 0.5` returned normally (rc 0) in 1.47 s on the Scarlett. Baseline right after, on BlackHole: 0.92 s. Not a hang; the Scarlett's device restart probably accounts for the difference. |
| extra | Sample-rate change while running (Scarlett 48k to 44.1k to 48k) | Each change was detected (device, stream-format and aggregate events), and the engine was rebuilt at the new rate about 1.1 s later (start 54–56 ms). Processing continued at the same level, 0 overloads. Rate restored to 48000 (verified). |

Logs: `App/.scratch/*.log`.

## Device inputs in the aggregate (the `channels-in: 0` question)

**Result: not possible with the documented keys.**
- `EQApe --probe` (tap + aggregate, no IO) on the Scarlett: the aggregate has **2 input streams (4 channels)**
  with or without `kAudioSubDeviceInputChannelsKey = 0` (also tried together with `channels-out`). The header
  describes it as a descriptive state key, and the HAL ignores it for a live device.
- The device's input stream therefore stays in the aggregate. It is switched off for our IOProc with
  `kAudioDevicePropertyIOProcStreamUsage` (NULL buffer, no input IO), as in poc-tap. `channels-in: 0` is still
  passed, harmlessly.
- Whether coreaudiod still runs the **Microphone** TCC check at `AudioDeviceStart` for such an aggregate could
  not be tested safely: Terminal now holds both AudioCapture and Microphone (preflight "granted" for both), so the
  headless runs prove nothing about a fresh identity. For the shipped app on a device with inputs (Scarlett), expect
  that **a Microphone prompt may appear in addition to the audio-capture prompt**. Devices without inputs (MacBook
  speakers, HDMI) produce an aggregate with only the tap as input.
- **Incident (handled):** one attempted workaround set `kAudioStreamPropertyIsActive = 0` on the aggregate's
  device-input stream. That property is settable, but the change **propagated to the real Scarlett input stream and
  persisted after the process exited**: the Scarlett input stayed IsActive 0 while other inputs were 1. It was
  immediately set back to 1 and verified (IsActive [1], still 1 at the end of the session). The code was removed,
  and the engine has a comment warning against it.
- A design that truly excludes the inputs would need a tap-only aggregate (input) plus a separate output IOProc on
  the device and a ring buffer. That means two IOProcs, more latency, and possible drift. It was not built.

## Not verified (cannot be, without a person)

1. **That the original sound is muted** (no doubled or phasey sound). Needs listening. The same caveat as poc-tap.
2. **The GUI with the engine:** the GUI was rendered offscreen and launched with `--no-engine` for a scripted
   in-process smoke test (see `docs/EDITOR-NOTES.md`). Never tested with the engine running: the meters, the A/B
   bypass, NSOpenPanel from an accessory app, the login-item toggle, and use by a person.
3. **The app's own permission flow:** the audio-capture prompt text, whether a Microphone prompt also appears (see
   above), whether the ad-hoc grant survives rebuilds, and whether the entitlement is needed under the hardened
   runtime.
4. Sleep/wake handling (the code exists: NSWorkspace will-sleep / did-wake). Unplug/replug of the Scarlett (handled
   by IsAlive, device-list and watchdog paths, but not exercised). Bluetooth, AirPlay, HDMI processing (HDMI was
   only used as a "no profile" device), and runs longer than 5 minutes.
5. Delivery of the NSWorkspace sleep/wake notifications in headless mode (it runs `RunLoop.main`; the GUI is the
   intended host).

## Known issues / limitations

- With a device that has inputs, the aggregate still contains them (see above). This may cost a Microphone prompt.
- Switching devices leaves a gap of about 0.3–0.9 s (debounce + teardown + start) in which audio plays unprocessed
  on the new device.
- System alert sounds go to the "system output" device, which is not tapped unless it is the same as the default
  output.
- `settings.json` is read at launch, written on changes, and (since the editor update) re-read when it changes on
  disk.
- In bypass (unusable config) the device is untouched. A save that leaves the file missing for longer than one
  poll (about 0.25–0.5 s) briefly tears down and rebuilds the engine. Normal and atomic saves do not.
- The headless `--follow-default` uses `~/Library/Application Support/EQ Ape/settings.json` unless `--settings`
  is given.
- The private TCC SPI (`TCCAccessPreflight`) is used read-only, for the headless safety net and informationally.
  If Apple removes it, the result is "unknown" and headless refuses to start without `--allow-prompt`.
- The meter is a peak over each read interval (headless 1 s, GUI 0.25 s). The clip count is cumulative across
  rebuilds for the whole run.

## First run for the user (checklist)

1. Build: `cd ~/code/standalone-mac-eq/App && ./bundle.sh`. Optionally copy `build/EQ Ape.app` to /Applications.
2. So that the two EQs do not stack, **first** stop the CamillaDSP service
   (`launchctl bootout gui/$(id -u)/<label of that service>`) and set the macOS output to **Scarlett Solo USB**.
3. Launch **EQ Ape.app** while you are at the computer. A slider icon appears in the menu bar.
4. Choose "Choose Config File…" and pick `/path/to/config.txt`. This creates the Scarlett profile and
   starts the engine.
5. **Answer the permission prompt(s) promptly** (audio capture, possibly also Microphone). An unanswered prompt
   blocks *all* new audio on the Mac until it is answered. If the menu says "audio start blocked", answer the
   prompt and choose "Reload".
6. Listening test for muting: play music quietly. Toggle "EQ Ape On" off and on. Off should sound like plain
   playback, on like the corrected sound, and you should **never** hear doubled, phasey or flanged sound (that
   would mean the original is not muted). Watch "Level" and the clip indicator; the anti-clipping gain should read
   about -9.41 dB (builds before 2026-11-12: -10.69 dB).
7. Switch the output to MacBook speakers or headphones. It should show "no profile" and play unprocessed.
   Switch back to the Scarlett and the EQ re-engages.
8. Optional: toggle "Launch at Login".
9. To return to the old chain: Quit EQ Ape, set the output to "BlackHole 2ch", and
   `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/<label of that service>.plist`.
