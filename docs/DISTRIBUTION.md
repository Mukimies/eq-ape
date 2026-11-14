# Distributing EQ Ape

Written 2026-11-11. Facts were checked against the web on that date; each claim carries a source number
`[n]` (list at the end). Anything marked **UNVERIFIED** could not be confirmed and must be tested or checked
by you before you rely on it. Companion files: `dist/release.sh` (local release build, run), `dist/make-dmg.sh`
(tested), `dist/update-cask.sh` and `dist/eq-ape.rb` (cask template), `.github/workflows/release.yml` and `ci.yml`
(written, **never run**). Sections 1 to 13 are the original planning text (2026-11-11); sections 0a and 0b below
were added when the first release was prepared (2026-11-12) and take precedence where they differ.

## 0. Decisions (fixed)

- **Name:** EQ Ape. Identifiers without the space: `EQApe`. Bundle `EQ Ape.app`, bundle id placeholder `org.eqape.EQApe`, DMG `EQ-Ape-<version>.dmg`, Homebrew cask token `eq-ape`, repository `github.com/Mukimies/eq-ape`.
- **Architecture:** Apple Silicon (arm64) only. No universal build.
- **Distribution:** DMG on GitHub Releases (plus an optional personal Homebrew tap). Not the App Store.
- **Licence:** Apache-2.0 with the Commons Clause (`/LICENSE`). The project is **source-available**, not open source, and must not be described as open source.
- **No GPL code may be copied in.** Equalizer APO (GPL-2.0-or-later), BlackHole and CamillaDSP are behavioural references only; see `docs/APO-PARITY.md` for what was consulted.

The sections below are background and procedure for carrying these decisions out.

## 0a. What is real and what is still planned (2026-11-12)

Real (exists in the repository, and was run where stated):
- `dist/release.sh <version>`: tests, bundle, version stamp, ad-hoc signature, DMG, checksum, filled-in release notes. **Run** for `0.1.0-beta.1`.
- `dist/make-dmg.sh`: run through `release.sh`. Its Developer ID and notarization branches have **never been executed**.
- `docs/releases/v0.1.0-beta.1.md` (release notes with `{{VERSION}}` / `{{SHA256}}` placeholders that `release.sh` fills in, written to `dist/out/RELEASE-NOTES.md`) and `CHANGELOG.md`.
- `.github/workflows/ci.yml` and `release.yml`: YAML parses (Ruby loader), reviewed by hand, **never run**; actionlint was not available. The runner label, Xcode version and action versions were checked against GitHub's published runner-images listing on 2026-11-12.
- `dist/eq-ape.rb` and `dist/update-cask.sh`: `ruby -c` passes and `brew style` flags nothing but a frozen-string comment that casks do not need; `brew fetch --cask` and `brew audit --cask` passed for 0.1.0-beta.2 (Homebrew 7.0.13, 2026-11-14); `brew install` was never run.
- `SECURITY.md`, `CONTRIBUTING.md`, issue template. Private vulnerability reporting is **disabled** on the repository as of 2026-11-12 (read-only API query); the owner must enable it (runbook step 2).
- Name conflict search: done, see `docs/DISTRIBUTION.md` section 10.

Still planned or open:
- Developer ID, notarization, Sparkle or any updater (section 3, 7).
- The TCC-survival test, the listening test and the self-signed-certificate test (section 12 items 3 and 4).
- A first real run of both workflows, and a download-and-open test of the released DMG on a second Mac.

**What varies between builds.** Same commit, same machine, two clean builds (`CLEAN=1`): Info.plist, icon and
`CodeResources` were byte-identical; the unsigned Mach-O differed in 36 bytes (the LC_UUID and about 19 scattered
bytes in the data/linkedit area, cause not investigated), so the ad-hoc signature (CDHash) differed; the DMG
differs on every build (hdiutil embeds its own timestamps and UUIDs; file times inside the stage are normalised to
the commit time). So **the SHA-256 is not reproducible**: a DMG built by CI and one built locally from the same commit
will have different checksums; publish exactly one and never mix. The build number (`CFBundleVersion`) is the commit
count of HEAD, so it changes with every commit; build the release from the final tagged commit. Inputs that make a
build differ across machines: Xcode/Swift version, macOS SDK. The `swift test` step is not part of the artifact.

## 0b. Cutting the release (v0.1.0-beta.1), in order

Prerequisites: the `release-prep` branch exists locally in the worktree and nothing has been pushed.

1. **Settle the content.** Merge the GUI work if it should be in the build. Resolve the `TODO` line in
   `docs/releases/v0.1.0-beta.1.md` (does this build contain the configuration editor / reworked GUI) and delete it;
   check the "not checked" list against reality; set the date in `CHANGELOG.md` (`## [0.1.0-beta.1] - YYYY-MM-DD`).
   Commit.
2. **Repository settings** (GitHub web UI, `Mukimies/eq-ape`): Settings > Code security > enable *Private vulnerability
   reporting* (SECURITY.md relies on it). Optionally protect `main` and check Actions are enabled.
3. **Merge and push.** Merge `release-prep` into `main` (a fast-forward or a PR), then `git push origin main`.
   This runs `ci.yml` for the first time; wait for it to go green and fix workflow problems before tagging.
4. **Dry run (recommended).** Actions > *release* > *Run workflow* on `main` with `dry_run` ticked and version
   `0.1.0-beta.1`. Download the workflow artifact and check it as in the verification list below. No release is created.
5. **Tag the final commit.** On `main`, with a clean tree: `git tag -a v0.1.0-beta.1 -m "EQ Ape 0.1.0-beta.1"` then
   `git push origin v0.1.0-beta.1`. This starts the `release` workflow.
6. **Wait for the workflow.** The `build` job runs the tests, builds, makes the DMG, and uploads it as an artifact;
   the `release` job then creates a **draft pre-release**. Read the job log, the Gatekeeper step (unsigned mode
   expects "rejected") and the job summary, which prints the updated Homebrew cask.
7. **Review the draft** (Releases page): it is marked *pre-release*; assets are `EQ-Ape-0.1.0-beta.1.dmg` and
   `EQ-Ape-0.1.0-beta.1.dmg.sha256`; the body has the checksum filled in and no `TODO` or `{{` left. Do **not** tick
   *Set as the latest release*. Download the DMG with a browser on a second Mac, run `shasum -a 256 -c` on it, and follow
   the install steps literally (Open Anyway, permission prompt: be at the machine and answer it).
8. **Publish** the draft in the GitHub UI. A tag-triggered failure after step 5 is fixed by deleting the tag locally and
   on the remote **before publishing anything**, fixing, and tagging again; never replace assets of a published release.
9. **Homebrew tap (optional).** Create `Mukimies/homebrew-tap`, add `Casks/eq-ape.rb` from
   `dist/update-cask.sh 0.1.0-beta.1 <sha256 or .sha256 file> > Casks/eq-ape.rb`, commit, push; test on a clean
   machine (see section 8 for what to expect).
10. **After publishing:** set the `CHANGELOG.md` link targets if needed, announce, collect feedback.

**Manual fallback** (workflow broken or not trusted): on a clean checkout of the tagged commit on an Apple Silicon Mac,
`dist/release.sh 0.1.0-beta.1`, then verify, then (tag pushed first)
`gh release create v0.1.0-beta.1 dist/out/EQ-Ape-0.1.0-beta.1.dmg dist/out/EQ-Ape-0.1.0-beta.1.dmg.sha256 --verify-tag --draft --prerelease --title "EQ Ape 0.1.0-beta.1" --notes-file dist/out/RELEASE-NOTES.md`,
then review and publish the draft as in steps 7 and 8.

**Verification list for any DMG** (never launch the app on a machine whose audio you need until you are ready to answer
the permission prompt): `hdiutil verify <dmg>`; `hdiutil attach -readonly -nobrowse <dmg>` shows `EQ Ape.app` and an
`Applications` symlink; `codesign --verify --deep --strict -vv` on the app; `plutil -p Contents/Info.plist`
(`CFBundleShortVersionString` 0.1.0, `EQApeReleaseVersion` 0.1.0-beta.1); `lipo -archs` prints `arm64`;
`spctl -a -vv` on an unsigned build says `rejected`; `hdiutil detach`.

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

**Workflow** (`.github/workflows/release.yml`, never run): on tag `v*` (or `workflow_dispatch`) the `build` job (runner
`macos-26`, arm64, `DEVELOPER_DIR` pinned to Xcode 26.6) runs `dist/release.sh`, which runs both test suites, builds and stamps the
bundle and makes the DMG; it branches on whether the signing secrets exist. Signed: import the .p12 into a temporary
keychain, store notarytool credentials from an API key, run with `DEVELOPER_ID` and `NOTARY_PROFILE`, delete the
keychain. Unsigned: nothing set. The DMG, checksum and release notes go up as a workflow artifact. The separate `release`
job (ubuntu, the only job with `contents: write`) runs only for tags and never for a dry run, and creates a **draft**
release (pre-release when the version has a `-` suffix) with `gh release create --draft`; a human publishes it. Facts
checked on 2026-11-12: `macos-26` is arm64 and `macos-latest` points to it; the image (20261102.0473.1) has Xcode 26.6
(17F113) as default, the same build as the local one (Swift 6.3.3 here); macOS 14 images were retired on 2026-11-02 [15];
current majors `actions/checkout` v7, `upload-artifact` v7, `download-artifact` v8 (latest GitHub release tags);
creating a release needs `contents: write` (the REST docs say only that push access is required; `contents: write` is the
token permission that grants it, not stated verbatim on the page I read). Package tools versions: App 6.0, EQCore 5.9.

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

**Personal tap: yes, once the release is published.** The tap repository must be named `homebrew-<name>`: create
`Mukimies/homebrew-tap` (short name `Mukimies/tap`) with `Casks/eq-ape.rb` (template: `dist/eq-ape.rb`). Per release,
`dist/update-cask.sh <version> <sha256 | dmg | .sha256 file>` prints the cask with `version` and `sha256` replaced
(the release workflow prints it in its job summary; nothing pushes it automatically). Install:
`brew install --cask Mukimies/tap/eq-ape` (or `brew tap Mukimies/tap` first).

What the user will experience (sources: Homebrew 5.0.0 announcement [16], the TomatoBar issue thread [25], and the
source of Homebrew 7.0.13 read on the author's machine, 2026-11-12; the cask was fetched and audited on 2026-11-14 but **never installed**,
and the whole sequence below is **unverified end to end**):
1. *Trust.* Homebrew 7.x requires non-official taps to be trusted before it loads their casks (`brew trust`; the
   `HOMEBREW_REQUIRE_TAP_TRUST` behaviour is the default). Reading the source: `brew install --cask Mukimies/tap/eq-ape`
   (fully qualified name typed on the command line) is explicitly allowed for `install`, `reinstall` and `upgrade`, but after a
   plain `brew tap` the short `brew install --cask eq-ape` or a bare `brew upgrade` would be refused with "Refusing to
   load cask ... from untrusted tap ... Run `brew trust ...`". Older Homebrew versions have no such step. The README should
   give the fully qualified command and mention `brew trust Mukimies/tap`.
2. *Quarantine.* Homebrew still sets the quarantine attribute on the downloaded DMG and propagates it to the app
   (source of `cask/quarantine.rb`, agent name "Homebrew Cask"). The `--no-quarantine` flag is deprecated and gone [16][25].
   So the installed app is quarantined, macOS refuses the first launch, and the user does the same Open Anyway step as
   with a browser download (or `xattr -dr com.apple.quarantine "/Applications/EQ Ape.app"`). The cask's `caveats` block
   prints these instructions after install.
3. *Gatekeeper deprecation.* The "has been deprecated because it does not pass the macOS Gatekeeper check" warning and
   disabling seen in the reports are for casks in the official homebrew-cask repository ("We will disable all
   Homebrew/homebrew-cask casks that fail Gatekeeper checks in September 2026" [16]); it comes from a `deprecate!`/`disable!` stanza in
   the cask, which our cask does not have. I found nothing saying a third-party tap's cask is blocked for being unsigned.
4. *Upgrades.* Homebrew's source carries a user's Gatekeeper approval across an upgrade only when the signing identity
   is unchanged (`cask/upgrade.rb`); an ad-hoc signature changes with every build, so expect the Open Anyway step and a new
   audio-capture permission after each upgrade (the second is TCC behaviour, see section 2, **unverified**).
Do not add a `postflight` that strips quarantine: it works against Homebrew's stated policy [16][17] and is a bad look for
a security-sensitive app.

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

**Naming hygiene.** "EQ Ape" is the decided name. **Conflict search (2026-11-12, quick, not legal advice, no
trademark-register search was possible):** web search for "EQ Ape", "EQApe", "eq-ape": no product or project of that name
found. GitHub repository and code search: only `Mukimies/eq-ape` itself. Homebrew cask list (7824 casks): no `eq-ape`; the
`ape` token is "ApE (A Plasmid Editor)", unrelated; `eqmac` exists (different name). Apple's public iTunes search API for
"EQ Ape", "EQApe", "eq-ape" (macOS and all software): no app of that name; neighbours are generic equalizer apps
("Equalizer - Music Player with 10-band EQ", "Sound Contour: Equalizer", etc.). Trademark aggregators showed no "EQ APE"
or "EQAPE" mark; nearest: "EQ.APP" (serial 98386815, Class 42, a different mark), several unrelated "EQ" marks, and a dead
"APE" application (serial 98547228, Classes 9 and 42, by another company). Note that ".ape" is the Monkey's Audio file
extension, so "APE" evokes that audio format (association only). The USPTO/EUIPO/WIPO registers were not queried
directly; do that before investing in branding. Do not use
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

(Status 2026-11-12: item 1 done except the official trademark registers; items 6 and 7 are written but not pushed or run; the runbook is in section 0b.)

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
25. https://github.com/ivoronin/TomatoBar/issues/102 (fetched 2026-11-12: Gatekeeper deprecation warning, `--no-quarantine` gone, `xattr` workaround)
26. https://github.com/actions/runner-images and its macos-26-arm64-Readme.md (fetched 2026-11-12: labels, Xcode 26.6 default, image 20261102.0473.1)
