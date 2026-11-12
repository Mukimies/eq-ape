# Validating GUI changes (agents and contributors)

Date 2026-11-12. macOS 26.6, Apple Silicon. Everything here is development tooling: it is off in normal use and only
active with explicit launch flags or scripts.

EQ Ape's GUI can be driven and inspected in two ways:

| | In-app channel (`scripts/uitest`) | Real input (`scripts/uidrive`) |
|---|---|---|
| How | The app watches a directory for JSON commands and posts NSEvents into **its own** event queue | Real CGEvents through the window server, the accessibility API of another process, `screencapture` |
| OS permissions | none | Accessibility (events, tree) and Screen Recording (screenshots) for the terminal |
| Touches the person's pointer/keyboard | no (but the dev app takes keyboard focus, see "Caveats") | yes: moves the real pointer, types into the frontmost app |
| Screenshots | the app draws its own live windows (sheets, popovers, alerts included) | real compositor pixels of one window |
| CI | yes (non-blocking step, never run there yet) | no |

Nothing here can hear. Audio results are measured, not heard: the channel's `state` reports the engine state, input and
output peak meters, peak hold, the clip count, the plotted peak and the anti-clipping gain. Whether the EQ sounds right,
whether the original is muted (no doubled sound) and how dragging feels still need a person.

## Prompt safety (read first)

An unanswered audio-capture or Microphone prompt freezes all new audio on the Mac (`docs/TAP-FINDINGS.md`, "Incident").
The rules the tooling enforces:

- `--require-granted`: the app checks the no-prompt preflights before any tap is created: the audio-capture permission
  must be "granted" for the responsible process. The Microphone status is reported but does not gate (no Microphone
  prompt was observed on a Scarlett Solo USB with the status "not determined"; `docs/APP-NOTES.md`). Otherwise the engine stays off with the state
  `engine off: <reason>` (menu, status strip, `state`) and a line on stdout. It re-checks every 5 s. Every scripted
  or unattended launch uses it; `uitest` always passes it.
- `--no-engine` never creates taps or starts device I/O. It is `uitest`'s default and the only mode the suite uses.
- The **responsible process** decides which grant applies: started from Terminal (as `uitest launch` does), the app
  runs under Terminal's grant; launched by Launch Services (`open`, Finder, `uitest launch --own-identity`), under
  its own code identity. `EQApe --print-permission` prints both preflights, the responsible process and the code
  identity as one JSON line and exits.
- Instance guard (always on in the GUI): a second EQ Ape process must not tap a device another one is processing (the
  audio would be processed twice). See "Several instances".
- Never run anything from `App/build/` for testing: it is the owner's working copy. Build dev bundles with
  `cd App && BUILD_DIR=build-dev ./bundle.sh`; `uitest` refuses any bundle outside `App/build-dev/`.

## In-app channel

`EQApe --ui-test-control <dir>` (plus the usual `--no-engine`, `--settings`, `--backup-dir`, `--editor`) makes the app
poll `<dir>/cmd/` for `*.json` files (temp file + rename), run them one at a time in name order and answer in
`<dir>/res/<same name>` (also atomic). `<dir>/app.json` appears when the channel is ready. No sockets. In this mode the
app also never writes window frames or the first-run flag to the shared `org.eqape.EQApe` user defaults, records
instead of opening Finder or System Settings (`state.app.opened`), and refuses to touch the login item.

UI actions are real AppKit events (`NSApp.postEvent`) aimed at the on-screen frame of an element found by its
**accessibility identifier** in the app's own accessibility tree (the same objects VoiceOver reads). Key events are
built as CGEvents and converted, so shortcuts behave as for a keyboard; typed characters are exact whatever the layout.

| Action | Fields |
|---|---|
| `ping`, `state`, `activate` | |
| `open` / `close` | `window`: editor (`path`), settings, firstRun; close also `sheet`, `popover` |
| `select` | `row` (id), `index` or `match` (text): selects a list row (model path) |
| `click`, `doubleClick`, `rightClick` | `target` (identifier, or `id>label` for a child such as a radio button `row.x:7.mode>31-band`), optional `offset` [dx, dy], `at` left/right, `modifiers` |
| `drag` | `target`, `to` (identifier) and/or `dx`, `dy` (points, dy > 0 = up), `steps`, `modifiers` (option, shift, command, control) |
| `scroll` | `target`, `dy`, `dx`, `precise` |
| `key` | `key` (letter, `tab`, `return`, `escape`, `delete`, `forwardDelete`, arrows, `home`, `end`, `space`), `modifiers`, `repeat`, optional `target` to click first |
| `type` | `text`, `target` (clicked until it has focus), `selectAll`, `commit` (Return) |
| `press` | accessibility press (VoiceOver path, no events) |
| `menu` | no menu open: opens the menu bar extra; else the menu being tracked (pop-up, pull-down, context menu). `item` picks by title, without it lists the items |
| `alert` | current alert or modal panel: texts, buttons; `button` presses one (an open panel's Cancel works too); `shot` saves it |
| `wait` | `path` into the state JSON (`editor.rows[2].text`), one of `equals`, `notEquals`, `contains`, `exists`, `gt`, `lt`; `timeout` |
| `shot` | `window` (editor, settings, firstRun, sheet, popover, alert, all), `name` or `path`: PNG of the live window plus its sheets and popovers, current appearance |
| `elements`, `audit`, `tree` | identifiers with frames; interactive elements lacking an identifier; the raw accessibility tree |
| `move` | `row`, `to` (row index in its file): the list's `onMove` path (see "Limits") |
| `resize`, `appearance` | `width`/`height`; `mode` light / dark / system |
| `quit` | flush, stop, exit |

`state` returns: app (pid, active, focus, first responder, appearance, recorded "opened" URLs), engine (state, kind,
device, config, applied anti-clip gain, A/B bypass, sample rate, rebuilds, reloads), meters (in/out dB, peak hold, clip
count, clip light), permission preflights, windows, settings profiles, an open menu or modal, and the editor (path,
rows with id/kind/text/channels/enabled/GraphicEQ layout and nodes, selection, selected node, warnings, plotted peak and
anti-clip gain and label, undo/redo availability and names, pending saves, notices, errors, sheet).

### Accessibility identifiers

Stable, also useful for VoiceOver and for `uidrive`:

- editor: `editor.file`, `editor.add` (split button: `at` left = Add, right = menu), `editor.undo`, `editor.redo`,
  `editor.revert`, `editor.opt.preamp|antiClip|selected|peak`, `editor.graph`, `editor.list`, `editor.node.freq|gain|remove`,
  `editor.status.engine|antiClip|bypass|warnings|notice`, `editor.meter.in|out`, `warnings.item.<n>`;
- graph children (buttons for VoiceOver: press selects, increment/decrement ±0.5 dB): `graph.handle.<file>:<line>`,
  `graph.node.<n>`;
- list rows: stem `row.<file>:<line>` plus `.label`, `.text`, `.on`, `.type`, `.fc`, `.fc.field`, `.gain`, `.gain.field`,
  `.q`, `.q.field`, `.bw`, `.bw.field`, `.slope`, `.slope.field`, `.preamp`, `.preamp.field`, `.delete`, `.enable`;
  GraphicEQ rows `.power`, `.mode`, `.sliders`, `.graph`, `.node.<n>`;
- band sheet: `geq.mode`, `geq.flatten`, `geq.addBand`, `geq.removeBand`, `geq.done`, `geq.band.<n>`, `geq.band.<n>.freq`,
  `geq.selected.freq|gain`;
- Settings: `settings.profile.<device UID>.enabled|choose|edit|antiClip|headroom|remove`, `settings.current.choose`,
  `settings.launchAtLogin`, `settings.openSettingsFolder`, `settings.openBackups`, `settings.privacy`;
- first run: `firstRun.notNow`, `firstRun.choose`.

Row identifiers contain the line number, so they change when lines are inserted above; read them from `state`.

## The driver: `App/scripts/uitest`

```sh
cd App && BUILD_DIR=build-dev ./bundle.sh          # dev bundle (never App/build/)
scripts/uitest launch                               # --no-engine, generated scratch config + settings + backups
scripts/uitest launch --config ~/EQ/config.txt      # scratch COPY of that file and its sibling .txt files
scripts/uitest do click target=editor.add at=left
scripts/uitest do type target=row.suite.txt:3.fc.field text=250 selectAll=true commit=true
scripts/uitest do menu                              # menu bar extra items
scripts/uitest state editor.selection
scripts/uitest shot my-change [editor|settings|sheet|all]
scripts/uitest quit
scripts/uitest status                               # session and every EQ Ape process (dev or not)
scripts/uitest suite                                # the end-to-end suite (below)
```

Session files live in `App/.scratch/uitest/session/` (`app.log`, `ctl/`, `config/`, `settings.json`, `backups/`).
`launch --engine` adds `--require-granted` and is refused while any other EQ Ape process runs. `--own-identity` launches
through Launch Services (the app is its own TCC responsible process). `--settings`/`--in-place` use real files only when
asked. `quit` only ever signals the session's own pid after checking it runs from `App/build-dev/`.

## The suite: `scripts/uitest suite`

About 110 checks in 20 steps, 1.5–3 minutes, on a fresh `--no-engine` dev instance with a generated config (preamp,
three filters, a commented filter, a variable GraphicEQ, an invalid line, an Include). Screenshots go to
`App/.scratch/uitest-suite/<time>/` (`--out <dir>` to change). Exit status 0 = all passed.

Covered, with real UI actions unless marked: graph handle drag, option-drag (Q), scroll wheel (Q), double-click to add;
⌘Z / ⇧⌘Z and the toolbar buttons; GraphicEQ node click, ↑/↓/←/→ with and without shift, Tab / ⇧Tab, Delete, nodes in
the row graph; Tab order through a row's fields; number fields committed by Return and by Tab, decimal comma, invalid
text; the Type pop-up; Delete key and trash button on rows; the On checkbox and the GraphicEQ power toggle; the context
menu (Turn On/Off, Comment Out, Enable); Enable on a commented filter; every Add-menu item; the 15-band / 31-band /
Variable switch with its conversion alert (Cancel and Convert); reorder (`move`: model path, see "Limits"); the band-slider
sheet; the warnings popover and jump; Revert (and its undo); the menu bar extra (items, Settings…); every Settings
control except Launch at Login (switch, checkbox, stepper, Choose… with its open panel, Edit…, folder and privacy buttons,
Remove); the first-run window (opened six times in both appearances: regression for a crash); window resize down to the
minimum; dark appearance; finally undo of everything, after which both files are byte-identical to the originals.

## Real input: `App/scripts/uidrive`

```sh
scripts/uidrive perms                        # Accessibility / Screen Recording / post / listen, never prompts
scripts/uidrive tree                         # the dev instance's AX tree as other apps see it
scripts/uidrive click row.suite.txt:3.on     # also: drag <id> --to <id> | --dx --dy, key <name> --mods cmd, type <text>
scripts/uidrive shot out.png --window "EQ Ape Editor"   # that one window only (screencapture -l, no shadow)
scripts/uidrive pass                         # short real-input pass, compared with the channel
scripts/uidrive <anything> --dry-run         # print the plan, post nothing
```

Permissions are those of the terminal app: System Settings › Privacy & Security › **Accessibility** (events, tree) and
**Screen & System Audio Recording** (screenshots). When one is missing, `uidrive` says which toggle and stops; use the
in-app channel.

Risks and the rules `uidrive` applies before every action: the target element must be in a window of the dev instance
(pid from the uitest session, executable under `App/build-dev/`); that window must be frontmost (it is raised first,
then checked); the point must lie inside the window's frame; afterwards the pointer is put back where it was; and the
run aborts when the pointer is not where it was left or the HID system saw a key press, click or mouse movement that
was not ours (someone is using the computer). Screenshots never contain anything but the one dev window. Still: it moves
the real pointer for a moment and keystrokes go to the frontmost app, so run it only when nobody is typing, and keep it
short.

## Several instances

The owner's instance and dev instances can run at the same time. Each process built with this change writes
`$TMPDIR/org.eqape.EQApe.instances/<pid>.json` (engine "off", "following" or "active", device) and, while it has an
engine, holds an exclusive `flock` on `device-<UID>.lock` in the same folder (released by the kernel if it crashes).
Peers are found through the process table (any executable named `EQApe`, `proc_listallpids`/`proc_pidpath`), no
sockets. Before creating a tap, an instance keeps its engine off when another one is processing the same device, may
start on any device ("following"), or is an older build without a registry file (assumed to be processing). A
`--no-engine` instance declares "off", reads settings without writing them (unless `--settings`), creates no taps,
changes no device settings, and in UI-test mode writes nothing to the shared user defaults, so it cannot interfere.

## Caveats and limits

- **Keyboard focus.** Focus-dependent actions (typing, keys, the first click into a field) need the dev window to be
  key, so the dev app activates itself, taking keyboard focus from whoever is using the Mac. macOS's cooperative
  activation may refuse that while a person works in another app; then those steps fail. The suite marks such
  failures ("EQ Ape was not the active app") and says to rerun when the computer is idle.
- List drag-to-reorder: AppKit drag sessions follow the real pointer, so posted events cannot start one; the suite uses
  the list's `onMove` path (`move`), and `uidrive pass` does a real drag.
- Captures from the channel are drawn by AppKit from the live view tree (no window shadow; materials approximated);
  `uidrive shot` gives compositor pixels.
- NSOpenPanel's buttons are drawn by a remote view service: the channel can see the panel and cancel it, not browse.
- Not covered by anything here: how it sounds, trackpad feel, VoiceOver speech, Launch at Login, sleep/wake.

## Results, 2026-11-12

- Suite (in-app channel, `--no-engine`, dev bundle signed "EQ Ape Local Dev", owner's instance running alongside):
  106 checks passed, 0 failed (see the final run's summary in the report of that session); screenshots in
  `App/.scratch/uitest-suite/`. Earlier runs found two app bugs, both fixed: the number-field Return commit that
  reverted itself, and the first-run window crash (`docs/EDITOR-NOTES.md`, "Update 2026-11-12: UI-test tooling").
  Tooling issues fixed on the way: synthesised ⌘Z after an undo acted as Redo (now built from CGEvents), scroll events
  without a window, list rows only reachable through the old accessibility API, clicks during list re-layout.
- Real input (`uidrive pass`, Terminal had Accessibility and Screen Recording; the owner was using the Mac at the same
  time; about 50 s per pass, four passes 13:50–13:55): a real drag of a filter handle produced exactly the same line as
  the channel's drag (`Fc 154 Hz Gain -7.8 dB`), real ⌘Z undid it, real clicks toggled the On checkbox, a real list
  drag-to-reorder moved the row (impossible through the channel) and ⌘Z restored the order; screenshots were cropped
  to the dev window (`screencapture -l`). Real typing into the Fc field failed inside the pass while the same keys sent
  one command at a time committed correctly (Return included): the pass reused one event source that most likely
  kept ⌘ from the preceding ⌘A; typed events now carry explicit empty flags. That fix has not been run with real input.
- Seen while testing, not fixed: Tab stops after a row's last field; immediately after a toggle rebuilt the list
  rows, a click into a field can need a second click (the channel retries and reports `clicksToFocus`).
