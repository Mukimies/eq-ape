# Distributing EQ Ape

Written 2026-11-11. Facts were checked against the web on that date; each claim carries a source number
`[n]` (list at the end). Anything marked **UNVERIFIED** could not be confirmed and must be tested or checked
by you before you rely on it. Companion files in `dist/`: `make-dmg.sh` (tested), `release.yml` (draft CI
workflow, not yet in `.github/`), `eq-ape.rb` (draft Homebrew cask).

## 0. Decisions (fixed)

- **Name:** EQ Ape. Identifiers without the space: `EQApe`. Bundle `EQ Ape.app`, bundle id placeholder `org.eqape.EQApe`, DMG `EQ-Ape-<version>.dmg`, Homebrew cask token `eq-ape`, repository `github.com/Mukimies/eq-ape`.
- **Architecture:** Apple Silicon (arm64) only. No universal build.
- **Distribution:** DMG on GitHub Releases (plus an optional personal Homebrew tap). Not the App Store.
- **Licence:** Apache-2.0 with the Commons Clause (`/LICENSE`). The project is **source-available**, not open source, and must not be described as open source.
- **No GPL code may be copied in.** Equalizer APO (GPL-2.0-or-later), BlackHole and CamillaDSP are behavioural references only; see `docs/APO-PARITY.md` for what was consulted.

The sections below are background and procedure for carrying these decisions out.

## 1. Recommendation

Publish the first release as an **unsigned (ad-hoc signed), clearly labelled pre-release (v0.1.0-beta.1)** on
GitHub Releases, installed from a DMG or from a personal Homebrew tap, with an honest README section on how to
open it. That gets real users and bug reports without waiting for or paying Apple. Treat it as a stopgap:
because the app needs a permission grant that is tied to its code signature, an ad-hoc build will most likely
ask for the permission again after every update, and the official Homebrew cask repository no longer accepts
apps that fail Gatekeeper. Join the Apple Developer Program (99 USD per year) and move to Developer ID +
notarization **before v1.0, or as soon as the beta has more than a handful of users**, whichever comes first.
If you are willing to pay 99 USD now, go straight to Option B and skip the unsigned release; nothing else in
this document changes, and the `release.yml` workflow handles both.

Why: for a utility that sits in the audio path and asks for "audio capture" access, a Gatekeeper warning
followed by a permission dialog on every update is a trust and usability problem, not just an inconvenience.
But it is a problem you can accept for a beta read by technically inclined early adopters.

## 2. Option A: unsigned / ad-hoc release now

**What "unsigned" means here.** Apple Silicon Macs refuse to run completely unsigned arm64 code, so the
bundling script must keep the ad-hoc signature (`codesign --force --sign -`) (general macOS behaviour, not
re-checked today). An ad-hoc signature is not an identity; Gatekeeper treats the app as "from an unidentified
developer / not notarized".

**What a user must do on current macOS (15 Sequoia and 26 Tahoe).** Control-click > Open no longer bypasses
Gatekeeper since macOS 15 [1][2]. Apple's current procedure [3]:

1. Open the DMG, drag EQ Ape to Applications, double-click it. macOS shows a "not opened / cannot verify" alert;
   close it (the alert may offer only "Move to Trash" and "Done"; do not trash it) [4].
2. Open System Settings > Privacy & Security, scroll to the Security section, click **Open Anyway** next to the
   EQ Ape message, confirm with "Open" in the next dialog (it may ask for your password or Touch ID: UNVERIFIED) [3].
3. The app is then saved as an exception and opens normally by double-click [3]. The button is reported to stay
   available for about an hour after the failed launch [4a]; if it has vanished, double-click the app again.
4. Command-line alternative, which skips Gatekeeper for that one app: `xattr -dr com.apple.quarantine /Applications/EQ Ape.app` [5].
5. Building from source locally produces an app with no quarantine flag, so none of this applies [5].

Sources disagree on details for Tahoe (one site describes a toggle in Privacy & Security instead of a button
[6]; a 2024 report claimed 15.1 removed the path entirely [7] but Apple's own page and later reports show it
still works [3][4]). Test the exact wording on your own Mac and in a clean macOS 26 VM before writing the README
screenshots. Put the steps in the README and in every release's notes.

**How the permission prompt behaves.** Per `docs/TAP-FINDINGS.md`: creating the tap and aggregate needs no
permission; `AudioDeviceStart` is where coreaudiod asks TCC for `kTCCServiceAudioCapture`, and a standalone app
gets its own TCC identity (subject = the app) instead of Terminal's. The app needs `NSAudioCaptureUsageDescription`
in Info.plist. Do not include the device's input streams in the aggregate, or the user gets a second (Microphone)
prompt. Critical, see the incident description in `docs/TAP-FINDINGS.md`: an unanswered prompt blocks coreaudiod for every app on the Mac, so the
app must start audio off the main thread with a timeout and never raise a second request while one is pending.

**What breaks on each update.** TCC records a code requirement for each grant. For an ad-hoc signature that
requirement is the code hash (cdhash), so a new build is a different app to TCC. Apple DTS says exactly this:
unsigned or ad-hoc signed programs have no stable identity, so TCC cannot tell version N+1 is the same as N and
the fix is a stable signing identity [8]; community write-ups say the same [9]. Expect: after each update the
user must grant audio capture again (a stale old entry may remain in Settings). The exact visible symptom
(new prompt vs silent denial) is **UNVERIFIED**; the Homebrew cask docs themselves say users of unsigned apps
must re-enable them after each update [10]. Also, every update re-runs the Gatekeeper dance above when the new
DMG is downloaded by a browser. Test: build v1, grant, rebuild with a code change, relaunch, observe.

**Cheaper middle path (UNVERIFIED for audio capture, worth a 30-minute test).** A self-signed code-signing
certificate (Keychain Access > Certificate Assistant > Create a Certificate, type Code Signing) gives the app a
stable certificate-based requirement, so TCC grants should survive updates [9]. Gatekeeper still treats it as
unidentified, so users still do the Open Anyway steps once per download, but the audio permission would persist.
The .p12 can go into the CI secrets exactly like a Developer ID one. Note the trade-off: users who verify
signatures see a self-signed identity, which is no better than ad-hoc for trust.

## 3. Option B: Developer ID + notarization

**Cost.** 99 USD per membership year (individual and organisation cost the same, no waiver for individuals) [11][12].
Needs an Apple ID with two-factor authentication and identity verification. Lapsing the membership does not
invalidate already-notarized releases (general knowledge, UNVERIFIED), but you cannot sign new ones.

**One-time setup.**
1. Enroll at developer.apple.com/programs/enroll as an individual [11]. Approval can take from minutes to days.
2. Create a **Developer ID Application** certificate (Xcode > Settings > Accounts > Manage Certificates, or the
   developer portal with a CSR). Confirm with `security find-identity -v -p codesigning`.
3. Create notarization credentials. Either an app-specific password (appleid.apple.com) or an App Store Connect
   API key (.p8). Store them locally once:
   `xcrun notarytool store-credentials "eqape-notary" --apple-id ... --team-id ... --password ...`
   (or `--key AuthKey_X.p8 --key-id ... --issuer ...`). The name `eqape-notary` is what `NOTARY_PROFILE` refers to.
4. Decide entitlements. EQ Ape is not sandboxed. Hardened runtime is mandatory for notarization; a microphone
   style entitlement (`com.apple.security.device.audio-input`) may or may not be needed for process taps under
   hardened runtime: **UNVERIFIED, test the signed build with the real tap before the first notarized release.**
   Never ship `get-task-allow`.

**Per release** (what `make-dmg.sh` automates when `DEVELOPER_ID` and `NOTARY_PROFILE` are set):
1. Build the app; sign nested code first, then the app: `codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" EQ Ape.app`.
2. Zip with `ditto -c -k --keepParent`, `xcrun notarytool submit app.zip --keychain-profile eqape-notary --wait`;
   on failure `xcrun notarytool log <id> --keychain-profile eqape-notary`.
3. `xcrun stapler staple EQ Ape.app`.
4. Build the DMG, `codesign --timestamp --sign "$DEVELOPER_ID" file.dmg`, notarize the DMG the same way, staple it.
5. Check: `xcrun stapler validate file.dmg` and `spctl --assess --type execute -vv EQ Ape.app` (after copying out of the DMG).
`.app`, `.dmg` and `.pkg` can be stapled; `.zip` cannot [13]. Requirements recap (Developer ID certificate, hardened
runtime, secure timestamp, no get-task-allow): from Apple's notarization docs, but those pages are JavaScript-rendered
and my fetch returned only the title, so this list is from established practice and **not re-verified against the live page** [13].

**Benefit for EQ Ape specifically:** a Developer ID signature gives a stable requirement (team ID + bundle ID),
so the audio-capture grant survives updates [8], and the first launch shows only the normal "downloaded from the
internet, Open?" dialog.

## 4. When to use which

| Situation | Use |
|---|---|
| Private testing, your own machines | Ad-hoc, build from source (no quarantine) |
| First public pre-release, small audience, no account yet | Option A, labelled beta |
| Anything called 1.0, anything promoted beyond the first adopters, official Homebrew cask, Sparkle updates | Option B |

**First public release: v0.1.0-beta.1, Option A**, unless you decide to enroll first (then Option B and no stopgap).
Run the self-signed-certificate test (section 2) before release; if it works, sign betas with that certificate.

## 5. DMG

`dist/make-dmg.sh <App.app> <version> [volume-name]` writes `dist/out/EQ-Ape-<version>.dmg` and
`EQ-Ape-<version>.dmg.sha256`. Tested (see section 11). Choices:

- **Volume name:** `EQ Ape` (no version, so mounts do not pile up as `EQ Ape 0.1.0`, `EQ Ape 0.1.1`).
- **Layout:** the app plus an `Applications` symlink. No background image or pre-positioned icons: that needs
  Finder AppleScript (flaky on CI). If you want a polished window later, use the `create-dmg` tool locally and
  keep the script as the CI path.
- **Format:** `UDZO` (zlib, level 9), HFS+ for widest compatibility. A menu bar app compresses to a few MB.
- **Signing/notarizing:** DMG is signed with the same Developer ID (no hardened runtime flag needed for a DMG),
  notarized, and stapled. The app inside is also notarized and stapled first so it still passes after being copied out offline.
- **Naming and versioning:** SemVer. Git tag `v0.1.0` or `v0.1.0-beta.1`; `CFBundleShortVersionString` = `0.1.0`;
  `CFBundleVersion` = a monotonically increasing integer build number (Sparkle requires an increasing, well-formed
  value [14]). Artifacts: `EQ-Ape-0.1.0.dmg`, `EQ-Ape-0.1.0.dmg.sha256`. Never replace a published asset; ship a new patch version.
- **Checksums:** the `.sha256` file is in `shasum -c` format. Users: `shasum -a 256 -c EQ-Ape-0.1.0.dmg.sha256`.
  Put the hash in the release notes too. For the unsigned build also consider a GPG or minisign signature (QtPass
  does this with .asc files [5]); optional.
- **Architecture:** Apple Silicon (arm64) only, as decided; `App/bundle.sh` builds with `--arch arm64`.

## 6. GitHub

**Repository expectations.** `README.md` (see section 10), `LICENSE` (Apache-2.0 with the Commons Clause, section 9), `docs/`, `EQCore/`,
`App/`, `dist/` (scripts) with the workflow moved to `.github/workflows/release.yml`, `CHANGELOG.md`, `SECURITY.md`
(how to report), issue templates asking for macOS version, output device, and the TCC state. Enable GitHub Pages
only if you adopt Sparkle. Releases are created from tags; never commit binaries.

**Releases.** Tag `vX.Y.Z`, mark betas as pre-release, attach the DMG and the `.sha256`, state "notarized: yes/no" in the notes.

**Workflow** (`dist/release.yml`): on tag `v*` it runs the EQCore tests, builds the bundle, then branches on whether the
signing secrets exist. Signed: import the .p12 into a temporary keychain, store notarytool credentials from an API
key, run `make-dmg.sh` with `DEVELOPER_ID` and `NOTARY_PROFILE`, delete the keychain. Unsigned: run `make-dmg.sh`
with nothing set. Both upload the artifacts and create the GitHub Release (`gh release create`). The runner label
`macos-26` (arm64) exists [15]; macOS 14 images were retired on 2026-11-02 [15]. The workflow calls `App/bundle.sh`; check its arguments and output path against `docs/APP-NOTES.md` before the first run.

**Secrets to create** (Settings > Secrets and variables > Actions):

| Secret | How to get it |
|---|---|
| `MACOS_CERT_P12_BASE64` | Keychain Access > My Certificates > right-click the Developer ID Application cert > Export as .p12; `base64 -i cert.p12 \| pbcopy` |
| `MACOS_CERT_PASSWORD` | The password you chose during export |
| `DEVELOPER_ID` | The exact identity string from `security find-identity -v -p codesigning` |
| `NOTARY_API_KEY_P8_BASE64`, `NOTARY_API_KEY_ID`, `NOTARY_API_ISSUER_ID` | App Store Connect > Users and Access > Integrations > create a key; download the .p8 once; `base64 -i AuthKey_X.p8 \| pbcopy` |

Delete the local .p12 afterwards or keep it in a password manager. Secrets are not exposed to workflows from forks'
pull requests, which is right: the release workflow only runs on tags you push. The workflow YAML parses (checked
with Ruby's YAML loader) but has **never run**; do a dry run with `workflow_dispatch` on a private repo first.

## 7. Updates

| Approach | Pros | Cons |
|---|---|---|
| **Sparkle 2** | Standard Mac UX, signed update feed (EdDSA), delta updates | Adds a framework and the app's only network access; works best with Developer ID: Sparkle's own docs "strongly recommend" signing and notarizing, and warn that an ad-hoc signed app may not be allowed to load Sparkle with library validation on [14]. Does not fix the TCC reset for ad-hoc apps |
| **Check GitHub Releases** (one HTTPS request to the releases API, then open the release page) | ~50 lines, no framework, works unsigned | User re-downloads by hand; a network call contradicts a "no network" claim unless it is opt-in and documented |
| **Homebrew only** | No in-app code at all; `brew upgrade` | Only for brew users; official cask not available while unsigned (section 8) |

**Recommendation.** Beta (Option A): no auto-update; a manual "Check for Updates..." menu item that is off by
default, or just a "View releases" link, plus the Homebrew tap. At Option B / v1.0: adopt **Sparkle 2**.
Sparkle needs: SwiftPM dependency `https://github.com/sparkle-project/Sparkle`, Info.plist `SUFeedURL` and
`SUPublicEDKey`, a one-time `generate_keys` (private key goes into your login keychain; `-x` exports it for
CI as the `SPARKLE_ED_PRIVATE_KEY` secret), and `generate_appcast` over a folder of release archives [14]. The
appcast file can live on GitHub Pages (stable URL, e.g. `https://Mukimies.github.io/eq-ape/appcast.xml`) with the
enclosure URLs pointing at the GitHub Release assets. Back up the EdDSA private key: if you lose it you cannot
ship updates to existing installs (Developer ID signing is what allows key rotation [14]). Whether updates downloaded
by Sparkle skip the Gatekeeper quarantine prompt is **UNVERIFIED** (I believe they do, since Sparkle downloads are
not browser downloads). Sparkle's minimum macOS requirement was not stated on the page I read, but it is below 14.

## 8. Homebrew

**Official homebrew-cask: not now.** Homebrew 5.0.0 announced that casks failing Gatekeeper checks would be disabled
in September 2026 [16]; third-party reports (GitHub issues, a project page) confirm casks started being disabled on
2026-09-01 with `disable! ... because: :fails_gatekeeper_check` [17][18]. I found no official post confirming the enforcement
itself (UNVERIFIED beyond those reports). The Acceptable Casks rules say Gatekeeper-assessable apps "must not
require System Integrity Protection or Gatekeeper to be disabled or bypassed" [19]. The notability rules for a new
cask: at least 30 forks, 30 watchers or 75 stars, and for a **self-submission** (you submit your own app) 90 forks,
90 watchers or 225 stars; a repository younger than 30 days is normally ineligible [20]. So: notarized app, repo
older than 30 days, and the star threshold, then submit with `brew bump-cask-pr`/a PR.

**Does the licence affect eligibility?** Homebrew's published Acceptable Casks page and Package Acceptance Policy (both read on 2026-11-11) state no licence requirement for casks: they do not mention open source, proprietary or source-available licences. Casks are described as distributing "applications and other pre-built files published by the upstream developer". Homebrew can reject a package for "material legal ... risk" in its own words, and I found nothing about how maintainers treat the Commons Clause in practice, so whether a Commons Clause app is accepted is **UNVERIFIED**. Ask in the PR or an issue before investing in the submission. The personal tap below is not affected.

**Personal tap: yes, now.** Create a repo named `homebrew-tap` under the `Mukimies` GitHub account with `Casks/eq-ape.rb` (draft:
`dist/eq-ape.rb`, syntax-checked with `ruby -c`, never run through `brew audit`). Users: `brew install --cask Mukimies/tap/eq-ape`.
Update `version` and `sha256` per release (a small step in the release workflow could do this later). Unsigned apps
still arrive quarantined: Homebrew deprecated the `--no-quarantine` flag [16], so brew users will hit the same Open
Anyway step, which is why the draft has a commented `caveats` block. Whether `brew` applies its Gatekeeper check to
casks in third-party taps was **not verified**; other people maintain unsigned-cask taps [21], suggesting it is
allowed. Do not add a `postflight` that strips quarantine: it works against Homebrew's stated policy [16][17] and is a
bad look for a security-sensitive app.

## 9. Licensing

**Decision: Apache-2.0 with the Commons Clause** (`/LICENSE`). Why: the owner wants everyone to be able to use, read,
modify and share the code, including at work, but does not want others to sell it or a product or service whose value
derives substantially from it. A standard open-source licence cannot express that; the Commons Clause adds it on top
of Apache-2.0 (which also gives an explicit patent grant). Consequence: the project is **source-available**, not open
source (the Commons Clause fails the Open Source Definition), and the documentation must never call it open source.
This is a description of the choice, not legal advice.

**No GPL code may be copied in.** Equalizer APO is GPL-2.0-or-later (checked in `docs/APO-PARITY.md`: licence text and
per-file headers). Copied or closely translated GPL code would make the result a derivative work that would have to be
GPL, which is incompatible with the Commons Clause. EQ Ape therefore only reads the config file format and re-implements
the behaviour; the audit in `docs/APO-PARITY.md` records what was consulted and states that no code was copied.
BlackHole and CamillaDSP are references only. Third-party dependencies (for example Sparkle, if adopted later, which
has an MIT-style licence: UNVERIFIED here) must be compatible with the terms and listed in a notices file.

## 10. Naming, trademark, privacy, README

**Naming hygiene.** "EQ Ape" is the decided name. **Conflicts with existing products, trademarks or repositories were not searched; do that before the first release** (GitHub, web, trademark registers). Do not use
"Equalizer APO", "APO", or "eqMac" in the product name, bundle id, domain or icon, and do not reuse their logos
(a standing project rule). Describe compatibility factually, once, in the README: *"Reads Equalizer APO-style
configuration files (Preamp, Filter, GraphicEQ, Channel, Include). Not affiliated with, endorsed by or sponsored by
the Equalizer APO project. Equalizer APO is a trademark or product name of its respective owners."* Avoid slogans such
as "Equalizer APO for Mac" in titles or repo names. Name the other tools only in comparisons you can back up. Also mention
that REW exports can be loaded.

**Privacy statement (put in README and an in-app About text).**
- Audio is captured only to be filtered and played to the same output device; it is processed in memory,
  never written to disk, never sent anywhere.
- The app makes no network connections. (If you add an update check, say exactly what is requested and make it opt-in.)
- No analytics, accounts or telemetry; only a small preferences file and your EQ config files are stored locally.
- It needs the system audio capture permission, and nothing else (no microphone, no screen content). State why:
  macOS has no other way to process system output without a virtual driver. Explain that the permission shows up under
  Privacy & Security > Screen & System Audio Recording (the exact pane name on macOS 14.2 to 26 is UNVERIFIED here, check it).
- The source is available, so every claim above can be audited; point to the files that create the tap.

**README essentials.** One-sentence purpose and a screenshot of the menu; requirements (macOS 14.2+, Apple Silicon);
install (DMG, `brew install --cask Mukimies/tap/eq-ape`); **"Installing an unsigned build"** section with the section 2 steps
and the checksum command; why the permission is needed and what happens if you click "Don't Allow" (how to fix it in
System Settings); a warning that a pending, unanswered permission prompt can stall all audio until answered; supported
config syntax and known gaps; how to quit and how to uninstall (what to remove); known limitations (latency about 23 ms
per TAP-FINDINGS, per-device profiles, Bluetooth/AirPlay untested); privacy statement; licence; build-from-source steps;
the non-affiliation line; how to report bugs.

## 11. make-dmg.sh test result

Tested on macOS 26.6 (Darwin 25.6) with a dummy bundle named `EQ Ape.app` under `dist/.scratch`, to check that a space in the
app name works: `dist/make-dmg.sh "EQ Ape.app" 0.0.1-test` produced `EQ-Ape-0.0.1-test.dmg` (the file name uses hyphens, the
volume name keeps "EQ Ape"), `hdiutil verify` reported "checksum ... is VALID", attached with `-readonly -nobrowse`, the volume
contained `EQ Ape.app` and `Applications -> /Applications`, detached cleanly, `shasum -c` gave OK, and the usage and
`NOTARY_PROFILE without DEVELOPER_ID` errors worked. The signing and notarization branches (`DEVELOPER_ID`, `ENTITLEMENTS`,
`NOTARY_PROFILE`) were **not executed**: there is no identity and nothing may be sent to Apple. They need a first real run with
real credentials. Scratch files and the test DMG were deleted.

## 12. Launch checklist (in order)

1. Search for conflicts with the name "EQ Ape" (GitHub, web, trademark registers); replace the placeholder bundle id `org.eqape.EQApe` if needed, and check the `NSAudioCaptureUsageDescription` wording and paths in `release.yml`/`eq-ape.rb`.
2. Confirm no Equalizer APO code was copied (`docs/APO-PARITY.md`); `LICENSE` is already in place.
3. Run the TCC-survival test on a clean user account: ad-hoc build, then self-signed-certificate build, grant, update, relaunch. Record the result in `docs/TAP-FINDINGS.md`.
4. Run the pending items from TAP-FINDINGS (listening test: original muted, unmute on quit, unplug/replug, sleep/wake) so the README does not over-promise.
5. Decide signed vs unsigned for v0.1; if signed, enroll now (allow days).
6. Create the public GitHub repo (`Mukimies/eq-ape`); add README, LICENSE, SECURITY.md, issue templates; move `release.yml` to `.github/workflows/`.
7. Add the secrets (Option B) and run the workflow via `workflow_dispatch` on a private repo or a throwaway tag.
8. Tag `v0.1.0-beta.1`; check the Release has DMG + `.sha256`; download via browser on a second Mac/VM and follow your own README steps literally.
9. Create `homebrew-tap` with the cask (real sha256); `brew install --cask Mukimies/tap/eq-ape` on a clean machine.
10. Announce (Equalizer APO forum threads, r/macaudio etc.) once the README is honest about the unsigned status.
11. Collect feedback for a few weeks; when the repo is older than 30 days and you are notarizing, consider the official cask [20]; add Sparkle at the same time.

## 13. Open decisions

Decided: name, licence, Apple Silicon only, GitHub Releases DMG (section 0).

1. Pay 99 USD/year for Developer ID now, or ship an unsigned beta first?
2. If unsigned: ad-hoc or a self-signed certificate (if the test shows it keeps the permission)?
3. Final bundle id (currently a placeholder), domain if any.
4. Updates: none/manual for the beta, Sparkle at 1.0? Is an opt-in network update check acceptable given the "no network" promise?
5. Whether to also notarize/sign with the hardened runtime audio-input entitlement (depends on the test).

## Sources

1. https://appleinsider.com/articles/24/08/06/apple-removes-control-click-option-for-skipping-gatekeeper-in-macos-sequoia (search result snippet; page not fetched)
2. https://9to5mac.com/2024/08/13/security-bite-apple-finally-making-it-harder-to-override-gatekeeper-is-a-telling-move/ (search snippet)
3. https://support.apple.com/en-us/102445 (fetched: Open Anyway steps)
4. https://nektony.com/how-to/remove-non-notarized-apps-mac and https://macos-tahoe.com/blog/app-is-damaged-cant-be-opened-macos-tahoe-gatekeeper-quarantine-fix-2026/ (search snippets; third-party Tahoe 26.4.1 test)
4a. https://support.apple.com/guide/mac-help/mh40617 (search snippet: "about an hour"; page not fetched)
5. https://qtpass.org/macos (fetched: right-click Open no longer bypasses on macOS 15+; xattr, Open Anyway, build from source)
6. https://zevrix.com/allow-non-notarized-app (fetched; Tahoe steps differ from Apple's wording)
7. https://www.osnews.com/story/141055/bug-or-intentional-macos-15-1-completely-removes-ability-to-launch-unsigned-applications/ (search snippet, contested)
8. https://developer.apple.com/forums/thread/697278 (fetched: Apple DTS on ad-hoc signing and TCC)
9. https://nickboy-github-io.pages.dev/posts/tcc-cdhash-trap/ (search snippet, third-party: ad-hoc DR is the cdhash, self-signed cert stabilises it)
10. https://docs.brew.sh/Cask-Cookbook (fetched: `unsigned_accessibility` caveat, `auto_updates`, `livecheck`, `zap`)
11. https://developer.apple.com/programs/enroll/ (search result; fee 99 USD per membership year)
12. https://developer.apple.com/support/compare-memberships (search result; same fee, waivers only for nonprofits/education/government)
13. https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution (fetch returned title only; content from established practice, not verified)
14. https://sparkle-project.org/documentation/ (fetched)
15. https://github.com/actions/runner-images (fetched: macos-26 arm64 label, macOS 14 retired 2026-11-02)
16. https://brew.sh/2025/11/12/homebrew-5.0.0 (fetched: Gatekeeper-failing casks disabled Sept 2026; quarantine flags deprecated)
17. https://qtpass.org/macos (reports `disable! date: "2026-09-01", because: :fails_gatekeeper_check`)
18. https://github.com/hluk/CopyQ/issues/3498 and https://github.com/ahrm/sioyek/issues/1666 (search results only)
19. https://docs.brew.sh/Acceptable-Casks (fetched)
20. https://docs.brew.sh/Package-Acceptance-Policy (fetched: 30/30/75 and 90/90/225 thresholds, 30 days)
21. https://github.com/JosephAlton/homebrew-other-cask-tap and https://github.com/SoftwareRat/homebrew-unsigned-tap (search results: community taps for unsigned casks)
22. https://sourceforge.net/projects/equalizerapo/ (fetched: GPLv2)
23. https://sourceforge.net/p/equalizerapo/code/ci/bbfcc3e5024cbb9d61ba75fc88d78605cc4c9687/tree/License.txt (fetched: GPL v2 text)
24. https://sourceforge.net/p/equalizerapo/ (author attribution from a search summary; secondary)
