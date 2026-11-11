# Tap PoC findings (`poc-tap/`, CLI `eqtap`)

Date 2026-11-11. macOS 26.6 (Darwin 25.6), Apple Silicon, Xcode 26.6 / Swift 6.3, ad-hoc signing.

**Result:** the preferred design works. The tap of one device and the real device sit in one private
aggregate device. One IOProc captures, processes and plays back in the same cycle on the device's own
clock. Measured on the Scarlett Solo USB and on the MacBook Pro Speakers: real non-zero audio,
processing applied, 0 overloads, 0 timestamp discontinuities, about 23–24 ms of in→out span. Muting of
the original is **not** verified by measurement. It needs a listening test (commands at the end).

## Build / commands

```sh
cd poc-tap && ./build.sh     # swift build -c release + ad-hoc re-sign + build/eqtap.app
B=.build/release/eqtap
$B list                      # output devices: id, name, in/out channels, rate, transport, *default / *system, UID
$B get-default | set-default "<name|UID>" [--system]
$B perm                      # TCC preflight (private TCC SPI, read-only, never prompts)
$B taps | cleanup            # list / destroy leftover *public* eqtap taps and aggregates
$B run --device "Scarlett Solo USB" [--seconds N] [--gain dB] [--peak f,dB,Q]... [--bypass] [--no-mute]
       [--mute-mode muted|when-tapped] [--buffer FRAMES] [--hold] [--public] [--start-timeout S]
$B disclaim <eqtap args>     # run eqtap as its own TCC responsible process instead of Terminal
scripts/scarlett-test.sh [device] [secs] [eqtap args]   # author-specific guarded test (restores the author's previous audio setup); adapt before use
```

The processing hook is a single closure, `ProcessFn = (UnsafePointer<UnsafeMutablePointer<Float>>,
channels, frames) -> Void`: non-interleaved buffers, processed in place (`DSP.swift`). The engine builds
it after the tap format is known and before IO starts (`TapEngine(device:options:makeProcess:)`). To plug
in EQCore, return `{ bufs, _, n in eq.process(bufs, frames: n) }`.

## API sequence that works (all verified against the SDK headers on disk)

1. `AudioObjectGetPropertyData(kAudioObjectSystemObject, kAudioHardwarePropertyTranslatePIDToProcessObject,
   qualifier = getpid())` returns our own process object (AudioHardware.h).
2. `CATapDescription(excludingProcesses: [self], deviceUID: <device UID>, stream: 0)`
   (CATapDescription.h `initExcludingProcesses:andDeviceUID:withStream:`; in Swift the
   refined init takes `[AudioObjectID]` and `UInt`). Set `name`, `uuid`, `muteBehavior = .mutedWhenTapped`,
   `isPrivate = true`. Excluding our own process prevents feedback, because our playback to the same
   device is not re-captured.
3. `AudioHardwareCreateProcessTap(desc, &tapID)` (AudioHardwareTapping.h). It needs **no** permission
   and succeeds silently. Then read `kAudioTapPropertyUID` (CFString) and `kAudioTapPropertyFormat`
   (ASBD). The observed format was 48 kHz, 2 ch, Float32, interleaved, the same as the device stream.
4. `AudioHardwareCreateAggregateDevice` with this dictionary (keys from AudioHardware.h):
   `name`, `uid`, `master` (`kAudioAggregateDeviceMainSubDeviceKey`) = device UID, `private` = 1, `stacked` = 0,
   `tapautostart` = 0, `subdevices` = [{`uid`: device UID}], `taps` = [{`uid`: tap UID, `drift`: 0}].
   Result: input streams = the device's own inputs (if any) followed by **the tap stream last**. Output
   streams = the device's outputs. On the Scarlett there were 2 input streams (Scarlett in, tap); on the
   MacBook speakers there was 1 (tap). The tap's input buffer is therefore the last one. eqtap computes
   this and shows per-buffer peaks (`inbufs[...]`) to confirm it. Measured: the signal was always in the
   expected buffer.
5. `AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil, block)`, then
   `kAudioDevicePropertyIOProcStreamUsage` (input scope) so that only the tap stream is on and the
   device's own inputs arrive as NULL buffers.
6. `AudioDeviceStart(agg, proc)`. **This is where the audio-capture TCC check happens** (see below).
7. In the block: deinterleave the tap buffer into scratch, run `ProcessFn`, interleave into the output
   buffers. No allocations or locks; counters and peaks go through C11 atomics (`RTAtomics`), because
   Swift's `Atomic` needs macOS 15.
8. Teardown, in this order: `AudioDeviceStop`, `AudioDeviceDestroyIOProcID`,
   `AudioHardwareDestroyAggregateDevice`, `AudioHardwareDestroyProcessTap`. It runs on SIGINT, SIGTERM,
   SIGHUP and SIGQUIT (dispatch signal sources) and on `--seconds`. It is bounded to 3 s, then `_exit`.

The Swift overlay (`AudioHardwareSystem`, `AudioHardwareTap`, `makeProcessTap`) is macOS 15+, so eqtap
uses the C API, which only needs macOS 14.2. One gotcha: the `kAudioAggregateDevicePropertySubTapList` IDs
are not resolvable from the client side (`no object with given ID`).

## Architecture chosen: single aggregate, single IOProc

Tap input and device output share one aggregate whose clock is the real device. Capture and playback
therefore happen in the same IO cycle on one clock: no ring buffer, no resampling, no drift correction
(`drift` = 0 on the sub-tap). This works, so the two-IOProc ring-buffer fallback was not built.

## Runtime results (measured)

Default output temporarily set to the device, the author's other audio routing stopped, `afplay -v 0.05 Glass.aiff` looped
in the background, 12 s per mode (`scripts/scarlett-test.sh`).

| Device | Mode | Input peak while playing | Output peak | Callbacks | Overloads | Discontinuities | in→out span |
|---|---|---|---|---|---|---|---|
| Scarlett Solo USB | `--gain -3 --peak 1000,3,1` | -40.1 dBFS | -42.5 dBFS | 1126 (727 non-zero) | 0 | 0 | 1112 fr = 23.2 ms |
| Scarlett Solo USB | same + `--bypass` | -40.1 dBFS | -40.1 dBFS (identical) | 1127 | 0 | 0 | 23.2 ms |
| MacBook Pro Speakers | `--gain -6` | -40.1 dBFS | -46.1 dBFS (exactly -6.0) | 563 | 0 | 0 | 1171 fr = 24.4 ms |
| MacBook Pro Speakers | `--bypass` | -40.1 dBFS | -40.1 dBFS | 563 | 0 | 0 | 24.4 ms |

- About 48 000 frames/s, IO buffer 512 frames. Zero-input callbacks are the gaps between the Glass
  repetitions (the tap delivers true digital silence when nothing plays).
- **Latency:** "in→out span" is `outputTime.mSampleTime - inputTime.mSampleTime` in the IOProc, on the
  aggregate's timeline. Aggregate figures on the Scarlett: input latency 74 + input safety offset 74,
  output latency 14 + output safety offset 14, buffer 512. The span measures how long ago the tapped
  samples were captured relative to when the replayed samples will be presented, so the **added delay is
  roughly 23–24 ms** compared with direct playback. That is a strong estimate, not an acoustic loopback
  measurement, but it is far below the 60–70 ms of a BlackHole + CamillaDSP chain the author used before and
  acceptable for lip sync.
- Runs were 6–12 s long. The "no dropouts over an hour" goal is not tested.

## Permission (TCC) behaviour, observed in tccd and coreaudiod logs

- Tap and aggregate creation need no permission. `AudioDeviceStart` on an aggregate containing a tap
  makes coreaudiod send a synchronous `TCCAccessRequest` for **kTCCServiceAudioCapture** (and
  **kTCCServiceMicrophone** when the aggregate includes the device's real input streams, as on the
  Scarlett). `AudioDeviceStart` **blocks until the prompt is answered**. It returns neither silence nor an
  error.
- When run from Terminal, the responsible process is **Terminal.app**: the prompt names Terminal, and
  tccd looks for `NSAudioCaptureUsageDescription` in Terminal's bundle (not found; it prompts anyway).
  eqtap's embedded plist is ignored in this case.
- The `__info_plist` section is embedded (linker `-sectcreate`). `codesign --force -s - --identifier
  <poc bundle id>` binds it (`Info.plist entries=5`). Run with `eqtap disclaim`
  (`responsibility_spawnattrs_setdisclaim`), TCC attributes to the PoC's bundle identifier with the binary path as
  subject, so a bare CLI *can* own its permission. The same applies to `build/eqtap.app` launched with
  `open`. That path was not completed: tccd queued ("Delaying prompt") the eqtap prompt behind the
  Terminal prompt that was already on screen.
- After the prompt was answered with Allow, tccd then reported `com.apple.Terminal` /
  kTCCServiceAudioCapture as allowed (request 90958.205), and request 90958.239 (Microphone,
  subject `.build/arm64-apple-macosx/release/eqtap`, identifier of the PoC) returned authValue 2.
  Afterwards `eqtap perm` (via Terminal) shows AudioCapture **granted**. `eqtap disclaim perm`
  (eqtap's own identity) shows AudioCapture and Microphone **not determined**, so the only
  **persistent grant is Terminal's AudioCapture permission**. The eqtap Microphone answer was not stored
  as a lasting record.
- **Rebuilds:** the grant belongs to Terminal, so it covers any rebuilt eqtap launched from Terminal
  (verified: several rebuilds since, still working). A standalone, ad-hoc-signed app has its own TCC
  identity (code requirement = cdhash). It will probably have to be re-approved after every rebuild that
  changes the code; a Developer ID signature avoids that. Not verified.
- Production consequence: ship as a signed .app with `NSAudioCaptureUsageDescription`. Leave the
  device's input streams out of the aggregate, or the app also needs Microphone permission. The
  `channels-in: 0` sub-device experiment could not be evaluated (see incident). Alternatively accept
  the Microphone prompt.

### Incident: a pending TCC prompt froze coreaudiod for all new clients

While the `eqtap disclaim` run's Microphone request (msgID 90958.239) waited behind the already
visible Terminal prompt, coreaudiod's later TCC checks queued behind it. Every new IOProc in
**any** process (eqtap and also `afplay`) hung in `HALC_ProxyIOContext::_TellServerAboutStreamUsage`.
Clients that were already running kept playing. Killing the requesting process did not
release it. The freeze ended when the prompt(s) were answered. Restarting the per-user `tccd` was
considered as a fix but not tried. Lessons for the app:
always call `AudioDeviceStart` off the main thread with a timeout (eqtap does, `--start-timeout`).
Never trigger a second, different TCC request while one is pending. Preflight
(`TCCAccessPreflight` / the documented user flow) before starting IO.

## Owner crash, unplug, mute safety

- **Private** tap + aggregate (the default): on `kill -9` of the owner, coreaudiod deactivated the
  aggregate within about 1 s (`HALS_Device::_Deactivate` in the log). Tested both while holding without IO
  and during live IO. Afterwards new clients start normally. The private tap is not visible to other
  processes, so its removal is inferred, not observed.
- **Public** objects (`--public`) **survive** `kill -9` of their owner (still listed 10 s later). Other
  processes can destroy them (`eqtap cleanup`, returned 0). A surviving public tap with
  `CATapMuted` would presumably keep the device muted. Therefore: use private objects plus
  `CATapMutedWhenTapped` (the header says it mutes only "for the duration of the read activity on the
  tap"), so a crash cannot leave audio muted. Not verified by ear.
- **Unplug/replug, sleep/wake, sample-rate change:** not tested. eqtap logs
  `kAudioDevicePropertyDeviceIsAlive`, `kAudioAggregateDevicePropertyActiveSubDeviceList` and
  nominal-rate changes. The expected handling is to tear down and rebuild the tap and aggregate on these
  events.

## Open questions from IDEA.md

- *Feedback / re-capture of our own output:* solved by `initExcludingProcesses:[own process object]`.
  Bypass output equals input exactly and nothing grows, which is consistent with no feedback loop.
  Verified only indirectly.
- *Mute reliable for every app:* the tap captures all processes playing to the device (afplay
  verified). Browsers and system sounds were not tested. Alert sounds go to the "system output"
  device (currently the MacBook speakers), so they need the system output tapped too, or the same device
  as default and system output.
- *Delay:* about 23–24 ms added (estimate above). No video compensation should be needed.
- *Bluetooth / AirPlay:* not tested.

## NOT verified

1. That the original audio is actually silenced (no doubled sound). No measurable proxy: a second tap
   sees process streams before muting, and the Scarlett has no loopback. **Needs listening.**
2. Acoustic latency (no loopback measurement). Long runs (1 h), unplug/replug, sleep/wake, rate changes,
   Bluetooth/AirPlay/HDMI, browsers.
3. The standalone `.app` / disclaimed permission flow end to end, and whether ad-hoc grants survive
   rebuilds.
4. The `channels-in: 0` sub-device key (whether it drops the device's inputs from the aggregate).

## Human listening test (about 2 minutes)

Run in Terminal (it holds the audio-capture permission now):

```sh
cd poc-tap && ./build.sh
# Author-specific guarded script: sets the default output to the Scarlett, loops a quiet Glass sound,
# runs eqtap 12 s normal, then 12 s --bypass, then restores the author's previous audio setup.
# Adapt it to your own setup (or run the manual steps below) before using it.
scripts/scarlett-test.sh "Scarlett Solo USB" 12 --peak 1000,6,1
```

Listen for: (a) normal mode: Glass sounds brighter/louder (+6 dB at 1 kHz), with **no** doubled,
phasey or flanged sound. Phasing would mean the original is not muted. (b) bypass: Glass sounds like
plain playback. For a clearer A/B with music, run manually: `eqtap set-default "Scarlett Solo USB"`,
stop any other audio-routing software, play music quietly, `eqtap run --device "Scarlett Solo USB" --peak 1000,9,0.7`, then
Ctrl-C. When it stops, music must continue unprocessed and at normal level (proves the unmute on exit).
Then restore your previous default output with `eqtap set-default "<previous device>"`.
