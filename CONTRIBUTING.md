# Contributing to EQ Ape

Bug reports, test results on other devices, and pull requests are welcome.

## Build and test

Requires an Apple Silicon Mac, macOS 14.2+, and Xcode 26 / Swift 6.x (the App package needs swift-tools 6.0).

```sh
cd EQCore && swift test     # DSP and parser tests
cd App && swift test        # app logic tests (no audio is started)
cd App && ./bundle.sh       # builds "App/build/EQ Ape.app" (arm64); does not launch it
cd App && BUILD_DIR=build-dev ./bundle.sh   # a development copy in App/build-dev/ (use it while App/build/ runs)
dist/release.sh 0.1.0-beta.1   # tests + bundle + DMG in dist/out/ (maintainers)
```

Tests that need a real config file skip themselves when `EQAPE_REAL_CONFIG` is unset; that is expected.

## Stable local signing (so the audio-capture permission can survive rebuilds)

macOS ties the audio-capture permission to the app's code signature: the grant is stored with the app's designated
requirement. An ad-hoc signature's requirement is its code hash (cdhash), which changes with every build, so each
rebuild is a new app to macOS and may ask again. A self-signed code-signing certificate gives a requirement that stays
the same across builds (`identifier "org.eqape.EQApe" and certificate leaf = H"<certificate hash>"`), so a grant given
once should keep applying. Whether it really survives a rebuild is being verified (see `docs/APP-NOTES.md`, "Stable
local signing"); until then, be at the computer for the first launch of each build.

`App/bundle.sh` picks the identity like this and prints it with the resulting designated requirement:

1. `SIGN_IDENTITY=<name, SHA-1 or ->` if set (`-` = ad hoc);
2. else, `EQAPE_LOCAL_SIGN=1`, or a local (non-CI) build and an identity named **EQ Ape Local Dev** exists in your
   keychain: that identity;
3. else ad hoc. CI and `dist/release.sh` always produce what they did before (release.sh sets `SIGN_IDENTITY=-`;
   Developer ID signing happens in `dist/make-dmg.sh`).

Create your own identity once (it never leaves your Mac; "not trusted" in `security find-identity` is expected and fine):

- Keychain Access › Keychain Access menu › Certificate Assistant › Create a Certificate… › Name `EQ Ape Local Dev`,
  Identity Type "Self-Signed Root", Certificate Type "Code Signing" › Create (login keychain).
- Or in Terminal:
  ```sh
  cat > /tmp/eqape-cs.cnf <<'CNF'
  [req]
  distinguished_name = dn
  x509_extensions = ext
  prompt = no
  [dn]
  CN = EQ Ape Local Dev
  [ext]
  keyUsage = critical, digitalSignature
  extendedKeyUsage = critical, codeSigning
  basicConstraints = critical, CA:false
  CNF
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config /tmp/eqape-cs.cnf -keyout /tmp/eqape.key -out /tmp/eqape.crt
  openssl pkcs12 -export -inkey /tmp/eqape.key -in /tmp/eqape.crt -name "EQ Ape Local Dev" -out /tmp/eqape.p12 -passout pass:eqape -legacy
  security import /tmp/eqape.p12 -k ~/Library/Keychains/login.keychain-db -P eqape -T /usr/bin/codesign
  rm /tmp/eqape.key /tmp/eqape.p12 /tmp/eqape-cs.cnf
  security find-identity -p codesigning     # lists "EQ Ape Local Dev" (CSSMERR_TP_NOT_TRUSTED is expected)
  ```
  (LibreSSL's `openssl` has no `-legacy` flag: drop it there.)

## Validating GUI changes

`docs/UI-TESTING.md` describes the tools: an in-app command channel (`App/scripts/uitest`, no OS permissions), a
scripted end-to-end suite (`App/scripts/uitest suite`, screenshots under `App/.scratch/`), and a real-input helper
(`App/scripts/uidrive`, needs your terminal's Accessibility and Screen Recording permissions). Run the suite after GUI
changes and look at its screenshots; say in your PR what you ran.

## Warning: unanswered permission prompts block all audio

The first `AudioDeviceStart` on an aggregate device with a tap makes coreaudiod ask macOS for the audio-capture permission and blocks until the prompt is answered. While a prompt is pending, no process on the Mac can start new audio. When you run a build that may raise a new prompt (a new signature, a new bundle), be at the machine and answer it. Start audio off the main thread with a timeout, never raise a second request while one is pending, never put the device's input streams in the aggregate, and never use public taps or aggregates. For runtime testing, run the command-line tools or the app's headless mode from a terminal that already holds the permission. For any scripted or unattended GUI launch, pass `--require-granted` (the engine then starts only if no prompt can appear) or `--no-engine`. Details: `docs/ARCHITECTURE.md`, `docs/TAP-FINDINGS.md`, `docs/UI-TESTING.md`.

## Licence of contributions

EQ Ape is Apache-2.0 with the Commons Clause (see `LICENSE`); it is source-available, not open source. By submitting a contribution you agree it is licensed under the same terms.

## No GPL code

Do not copy or closely translate code from GPL-licensed projects, in particular Equalizer APO. EQ Ape only reads its config format and re-implements documented behaviour (`docs/APO-PARITY.md`). Do not add dependencies whose licences are incompatible with these terms.

## Pull requests

Keep changes focused, add or update tests where there are tests for the area, and note in the PR what you did and did not verify (for example which output device).
