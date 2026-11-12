# Configuration editor and GUI notes

Date 2026-11-12. macOS 26.6.2, Apple Silicon, Swift 6.3.3. Screenshots: `docs/screenshots/` (rendered offscreen, see
"Verification").

EQ Ape's editor does what Equalizer APO's Configuration Editor does on Windows: it shows the frequency response of the
whole config and lets you change it while you listen. It edits the Equalizer APO text files themselves. Every change is
written about 150 ms later, and the running engine reloads the file about 0.35 s after that. Equalizer APO was used only
as a behavioural reference (its editor's screenshots and documentation). No code or assets were copied. Equalizer APO is
GPL; EQ Ape is source-available under Apache-2.0 with the Commons Clause.

![Editor, light](screenshots/editor-real-light.png)

## Design

### Document model (EQCore, additive public API)

- `ConfigLine.swift`: a single line-level interpreter (`LineInterpreter`) that both `APOParser` and the editor use.
  - `LineKind`: `blank`, `comment(command:)`, `command(ConfigCommand)` or `unknown(message:)`. For a comment, `command`
    is set when the text after `#` is itself a valid command (REW's commented-out filters). The `message` of an unknown
    line is exactly the warning `APOParser` emits.
  - `ConfigCommand`: `preamp`, `filter(FilterLine)`, `graphicEQ(points)`, `channel(names)` or `include(path)`.
  - `FilterLine` keeps the fields as written: label (filter number), ON/OFF, type name, Fc, Gain, Q, BW Oct and slope.
    It applies no defaults. `FilterLine.evaluate(line:)` builds the biquad and the warnings with exactly Equalizer APO's
    rules (moved unchanged out of the old `APOParser.parseFilter`).
  - `ConfigCommand.canonicalText` writes canonical, case-sensitive Equalizer APO syntax.
  - `APOFormat` gives the shortest round-trip number. A frequency never gets exactly three decimals: "60.812" would hit
    Equalizer APO's REW thousands-separator rule and be read as 60812 Hz, so it is written as "60.8120".
- `APOParser` now only adds channel selection, Include recursion and the `file:line:` prefixes on top of the
  interpreter. Its public API and behaviour are unchanged: the 29 existing tests pass unmodified.
- `ConfigDocument.swift`: a value type holding the encoding (UTF-8, UTF-8 with BOM, UTF-16 LE or BE with BOM) and an
  ordered list of lines. Each line keeps its text and its own terminator (`\n`, `\r\n`, `\r`, …). Lines are split
  exactly like the parser, so line numbers match its warnings.
  - Serialising an unmodified document is byte-exact. This is checked at load time: a file whose bytes cannot be
    reproduced from the decoded text (for example invalid UTF-8) is loaded `readOnly`. It is shown and evaluated, never
    edited.
  - Edits: `setCommand`, `setLineText`, `setCommented` (adds `# `, or removes `#` and the spaces after it, only when
    the comment is a valid command), `insertLine`/`insertCommand`/`appendCommand`, `removeLine` and `moveLine`.
  - An edit regenerates only its own line and keeps that line's terminator and leading indentation.
  - Structural edits keep the file's final-newline state and never move the final empty line.
- `ConfigWorkspace.swift`: the root file plus every included file, each as its own `ConfigDocument`, keyed by
  standardized URL.
  - `includeTree()` returns the tree, including missing files and cycles.
  - `evaluate()` returns the same `ParseResult` as `APOParser.parse(fileURL:)` would for the in-memory documents, and
    also where each stage and warning comes from (`LineRef`) and the channel selection at each line.
  - `edit(url, name, coalesceKey)` makes an undoable step. Consecutive edits with the same key merge into one step (a
    slider or handle drag) until `endCoalescing()`.
  - Also: `undo`/`redo`, `revertToOriginals()` (undoable), and `reloadFromDisk` (drops the undo history of that file).
  - New Include targets are loaded automatically after an edit.

### Live saving (EQApeCore)

- `ConfigEditSession` wraps a workspace.
  - It writes changed files 150 ms after the last edit, in place rather than by rename-over, which keeps the inode,
    permissions and extended attributes. The engine's watcher waits for the file to be stable for one poll before it
    reads.
  - Before the first write of each file in a session, `EditorBackups` copies the file to
    `~/Library/Application Support/EQ Ape/Backups/<yyyy-MM-dd_HH-mm-ss>/` with a `manifest.txt` of original paths.
    Only the newest 20 session folders are kept, and only folders with timestamp names are ever deleted.
  - It polls the files every 0.5 s. A file that changed on disk and differs from what the session wrote is reloaded.
    If the file had unsaved edits (only possible inside the 150 ms window), the user is asked.
- `ResponsePlot` computes the graph data.
  - The grid is 400 log-spaced points from 20 Hz to 20 kHz, plus the centre and band-edge frequencies of every biquad,
    so a Q 10 notch is drawn at its true depth.
  - Biquads use EQCore's exact magnitude, so high-pass, low-pass, notch, all-pass and band-pass are included. GraphicEQ
    uses its interpolated curve. Preamp can be included or excluded.
  - Anti-clipping uses the engine's own rule (`Response.peak`, 5 Hz–22 kHz, reference semantics), so the plotted peak
    and gain are the ones the engine applies.
- `TapController` gained:
  - `setABBypass(_:)`: one lock-free slot swap to "no processor" (unity), and back to the retained EQ box. It takes
    effect from the next IO cycle. A rebuild while bypassed stays bypassed.
  - `watchSettingsFile()`: settings.json is re-read when it changes on disk.
  - `setProfile(uid:_:)`.
  - `settingsReadOnly`.

### GUI (EQApe target)

- Windows are AppKit `NSWindow`s hosting SwiftUI. They can be opened from a menu bar app and at launch.
  - Editor: autosaved frame `EQApeEditor`, so it is resizable and remembers its size.
  - Settings: autosaved frame `EQApeSettings`.
  - First run: shown only when there are no profiles, the first run has not been completed, and the engine is enabled.
    The owner already has profiles, so it will not appear for them.
- The graph is an `NSView` (`ResponseGraphNSView`).
  - Grid: lines at the 1/3-octave centres, labels at 20/50/100/200/500/1k/2k/5k/10k/20k. The dB axis auto-scales in
    6 dB steps, never smaller than ±12 dB, and does not rescale during a drag. The 0 dB line is stronger.
  - Curves: one combined curve, or blue Left and orange Right when they differ. The selected line's own curve is a
    teal fill; it is dashed when the line is OFF or commented out and shown as if enabled.
  - Peak marker, with "peak +x dB at f → anti-clip y dB" in the top margin.
  - Hover read-out: frequency, the curve value (L and R) and the cursor level.
  - Handles: active peaking and shelf filters, coloured by channel, hollow when OFF. Drag changes frequency
    horizontally and gain vertically; option-drag or the scroll wheel changes Q; double-click adds a filter. A click
    alone never rewrites a line: only the components that moved are rounded and written.
  - Recomputing the plot per drag step is synchronous and takes a few milliseconds.
- Filter list (SwiftUI `List`): one section per file in Include order. Sections can be collapsed and are indented by
  include depth. Blank lines are hidden.
  - Filter row: ON checkbox, filter number, type picker (PK, LSC, HSC, LS, HS, LP, HP, LPQ, HPQ, BP, NO, AP, plus
    PEQ/Modal/None when present), Fc (log slider and field), Gain, then Q, BW or slope (default shelves show slope
    10.8), a channel badge (L or R) and delete.
  - Preamp row with a slider.
  - Channel lines appear as "Applies to: L" headers.
  - Include rows (marked "not found" if missing).
  - Comments are dimmed, with an Enable button when the comment is a valid command.
  - Unknown lines are dimmed, with a warning icon and a tooltip.
  - Context menu: Comment Out, Enable, Turn On/Off, Delete. Drag to reorder (`onMove`, within a file). Delete key.
  - "Add Filter" adds after the selected line, otherwise in the file with the most filters.
- GraphicEQ: the row shows a mini curve and an "Edit Bands…" sheet with vertical band sliders.
  - The existing points are kept.
  - Add Band (geometric middle of the selected and next band), Remove Band.
  - Band Layout: 10 (octave), 15 (2/3 octave) or 31 (1/3 octave) bands. The current curve is resampled, not
    discarded. Flatten.
  - Selected-band frequency and gain fields.
- Status strip: device and engine state, In and Out meters with peak hold and a clip light, the applied anti-clipping
  gain, the A/B bypass button, notices and save errors, and a warnings popover. Clicking a warning selects its line and
  scrolls to it.
- Undo and redo use toolbar buttons with ⌘Z and ⇧⌘Z. "Revert to Version at Open" is undoable.
- The menu bar menu is now:
  - EQ Ape On
  - device: state
  - Bypass (A/B)
  - (Reload, only in an error state such as "start blocked")
  - Open Editor… (⌘E)
  - Settings… (⌘,)
  - Quit
- Settings: every device profile (config path with Choose… and Edit…, Enabled, anti-clipping on/off, headroom
  stepper, Remove), a "Choose Config File…" entry for the current device if it has no profile, "Launch EQ Ape at login"
  (SMAppService, only when toggled), folder buttons, and a permission explanation with a button that opens System
  Settings › Privacy & Security at `Privacy_AudioCapture` (that anchor exists on this macOS; it falls back to
  `Privacy_ScreenCapture`).
- Launch flags (`LaunchOptions.swift`):

  | Flag | Effect |
  |---|---|
  | `--no-engine` | No engine, taps or device I/O. Device names are read only. Settings are read-only unless `--settings` is given. |
  | `--editor <path>` | Open the editor on that file. |
  | `--settings <file>` | Use this settings.json. |
  | `--backup-dir <dir>` | Write editor backups here. |
  | `--render-snapshots <dir>` | Render the views to PNG and exit; implies no engine. |
  | `--smoke-test` | Drive the editor in-process. |

  SIGTERM, SIGINT and SIGHUP flush pending editor saves, stop the controller and exit 0.
- Accessibility: every slider, field, toggle and button has a VoiceOver label (with a value where useful). The band
  sliders are focusable, respond to ↑/↓ in 0.5 dB steps, and support VoiceOver increment/decrement. Text fields are in
  the tab order. The graph exposes a summary value: peak, number of handles, and whether L and R differ.

## Verification

All of this was done without starting an audio engine, without opening or quitting anything in `App/build/`, without
playing sound, and without changing device settings.

**Automated tests**
- `EQCore`: 44 tests, 0 failures (29 existing + 15 new in `DocumentTests.swift`). The real-config test runs with
  `EQAPE_REAL_CONFIG` pointing at a scratch copy.
- `App`: 20 tests, 0 failures (13 existing, one of which is the real-config test run with `EQAPE_REAL_CONFIG`, + 6 in
  `EditorTests.swift` + 1 settings test).

The new tests cover:
- Byte-exact round trip on fixtures: LF, CRLF, no final newline, UTF-8 BOM with CRLF, UTF-16 LE, UTF-16 BE, mixed
  line endings, tabs and odd spacing, non-ASCII, empty, only-newline, and the REW style with commented filters and the
  `Filter  2: ON  PK       Fc   118.0 Hz  Gain -14.80 dB  Q 10.339` spacing. Invalid UTF-8 is read-only and still
  exact. The five files of the real config copy also round-trip byte-exact.
- Single-line edits change only that line's bytes, in every encoding and line-ending style.
- Canonical text reads back to the same fields, including the 3-decimal frequency guard.
- ON/OFF, Preamp, GraphicEQ, comment enable/disable, add/remove/reorder, and final-newline preservation.
- Include tree with a subfolder, backslashes, quotes, a missing file, UTF-16 and a cycle. Editing an included file
  changes only that document.
- Undo, redo, coalescing, revert, and no-op edits.
- Stage and warning equality with `APOParser` on 79 syntax snippets (every case in the parser and parity tests plus
  extras) and on all encoding fixtures.
- Backup creation, naming, manifest, pruning to 20 (an unrelated folder survives) and same-second sessions, in a temp
  directory.
- Debounced write: one write for 20 drag edits.
- External change and conflict handling.
- Live save picked up by EQApeCore's `FileWatcher` and `ConfigLoader` (no engine): the edited high-pass is read back
  with the expected stages, latency under 1.5 s.
- Plot numbers.
- settings.json re-read and read-only mode.

**Plotted curve vs EQCore**, real config copy, 48 kHz, preamp included, anti-clip excluded:

| Frequency | Plotted | Expected |
|---|---|---|
| 20 Hz | −4.16 dB | ≈ −4.2 dB with the high-pass (+10.09 dB without it, ≈ +10.1) |
| 40 Hz | +8.86 dB | ≈ +8.9 dB |
| 118 Hz | −16.15 dB | ≈ −16.2 dB |
| 200 Hz | −1.26 dB | |
| 500 Hz – 20 kHz | −1.00 dB | "0 dB above 200 Hz" |

- The brief's "0 dB above 200 Hz" holds only with Preamp excluded. With the −1 dB preamp included the flat part is
  −1.0 dB. Both are visible in the GUI: tick or untick "Preamp".
- Peak +10.19 dB at 5 Hz, so the anti-clipping gain is −10.69 dB. This equals the headless run in APP-NOTES.

**Rendered offscreen and inspected** (`--render-snapshots`, NSHostingView in a borderless window that is never shown;
the PNGs are in `docs/screenshots/`):

| File | View |
|---|---|
| `editor-real-light.png`, `editor-real-dark.png` | Real config copy (neutral file names), 118 Hz cut selected |
| `editor-real-anticlip.png` | Anti-clipping gain included in the curve |
| `editor-stereo-light.png`, `editor-stereo-dark.png` | Different left and right channels |
| `editor-commented-light.png` | REW export with commented filters and an OFF filter |
| `graphiceq-editor-light.png`, `graphiceq-editor-dark.png` | GraphicEQ band editor |
| `warnings.png` | Warnings list |
| `settings-light.png`, `settings-dark.png` | Settings |
| `first-run-light.png` | First-run window |
| `editor-no-engine.png` | Real `--no-engine` status |

The "active" status, meter levels and the profiles in the Settings snapshots are preview data. Fixed after looking:
- In dark mode the header and options bar were white on white: the view had no window background of its own.
- The "dB" axis label overlapped "+12".
- The peak label covered the curve; it is now in the top margin.
- The selected row was scrolled out of view.
- Shelves with the default slope showed "Q 0"; they now show slope 10.8.
- L and R handles were not distinguishable; they are now coloured by channel.
- The no-engine state read "error: engine disabled".
- The Settings snapshot showed the development-run notice.

Remaining rendering artefact: switches and slider knobs render in their inactive-window style, because the offscreen
window is never key.

**Run as the real GUI** (`build-dev/EQ Ape.app/Contents/MacOS/EQApe --no-engine --editor <scratch copy> --settings
<scratch> --backup-dir <scratch> --smoke-test`, started from the terminal, not with `open`):
- It started, put its menu bar item up and opened the editor window on the scratch copy, and stayed alive for 30 s.
- SIGTERM gave "signal 15, shutting down" and exit code 0.
- `--smoke-test` drove the window in-process with synthesised AppKit mouse events through `NSWindow.sendEvent`. No
  Accessibility permission is used: the events never leave the process.
  - A drag on the 60.8 Hz handle gave `Fc 81.7 Hz Gain -5 dB`, Q unchanged.
  - An option-drag gave Q 3.634 → 5.14.
  - A scroll gave Q → 3.63. This calls the view's scroll handler directly: a synthesised scroll event without a window
    carries screen coordinates.
  - The file on disk contained the edited line 0.7 s later (2 writes). `ConfigLoader` read the same stages as the
    editor.
  - Undoing every step restored the original bytes exactly; redo changed them again; undo restored them.
  - The band-editor sheet attached. The Settings window opened.
  - A backup folder with `manifest.txt` was created in the scratch backup directory.
- Not exercised in the running GUI:
  - Clicking or typing by a person.
  - Keyboard focus and Tab order.
  - VoiceOver.
  - Real scroll-wheel events.
  - List drag-reordering.
  - Popovers and alerts.
  - NSOpenPanel.
  - The meters with real audio.
  - The A/B bypass with a running engine. Its controller code path has no unit test and was never run with audio.
  - The first-run window on a fresh install.
  - `SMAppService`.
  - The conflict alert.

**Bundle:** `BUILD_DIR=build-dev ./bundle.sh` gives `App/build-dev/EQ Ape.app`. `codesign --verify --deep --strict`:
valid on disk and satisfies its Designated Requirement (adhoc, runtime, arm64). `plutil -lint`: OK. `App/build/` was
not touched: the mtimes and sizes of all 11 entries are identical before and after.

## Known issues

- The A/B bypass, meters, Live badge and anti-clip value come from the in-process engine. The editor of a `--no-engine`
  run shows "engine disabled". The currently running old build has no editor at all, so editing from the new build
  while the old one plays works through the file watcher only (no bypass, no meters).
- Undo/Redo (⌘Z) are window-level shortcuts, so ⌘Z inside a text field undoes the config edit, not the typing.
- A shelf's slope control on `LS`/`HS` (not `LSC`/`HSC`) writes an explicit "x dB" slope. In Equalizer APO that makes
  Fc a corner frequency, so the curve shifts. This is correct APO semantics, but surprising.
- The anti-clipping peak follows EQCore's reference semantics, which ignore high-pass filters. For the real config the
  peak is at 5 Hz (+10.19 dB), below the 30 Hz high-pass, so about 10.7 dB of gain is spent on bass that the HPQ removes
  anyway (APO-PARITY gap 5). The editor shows this honestly ("peak +10.2 dB at 5 Hz") but does not change it.
- List drag-reorder works within one file only. Moving a Channel line changes which lines it applies to (by design).
- Comment and unknown lines (REW headers) take a full row each, so long REW exports need scrolling.
- `--no-engine` runs write the editor window frame into the `org.eqape.EQApe` user defaults (autosave), like any run of
  the app.
- The settings watcher re-reads settings.json on change; the old running build still ignores external edits.

## Switching from the running build to the new one

1. Quit the running EQ Ape: menu bar slider icon › Quit EQ Ape. Audio returns to normal playback at once.
2. Build: `cd ~/code/standalone-mac-eq/App && ./bundle.sh`. This replaces `build/EQ Ape.app`, so only do it after
   quitting. Optionally copy the app to /Applications.
3. Launch `build/EQ Ape.app` while you are at the computer.
4. The rebuilt binary is a new ad-hoc identity, so macOS may ask for the audio-capture permission (possibly also
   Microphone) when the engine starts. **Answer immediately**: while a prompt is open no app can start audio. If the
   menu says "audio start blocked", answer the prompt and choose Reload.
5. Your profiles in settings.json are kept, so the first-run window does not appear. Open Editor… opens the current
   device's config. The original files are backed up before the first change of each session.
