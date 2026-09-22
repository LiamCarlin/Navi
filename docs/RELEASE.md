# Releasing Navi

How a commit on `main` becomes a notarized `Navi-<version>.dmg` that other people's Macs
will open, plus the `appcast.json` that tells installed copies to update.

```
scripts/release.sh
  ├─ xcodegen + xcodebuild Release            (build/DerivedData-release)
  │    └─ post-build phase: scripts/bundle-runtime.sh --into Navi.app   (Release only)
  ├─ codesign --options runtime, inside-out   (every Mach-O in the runtime, then the app)
  ├─ notarytool submit --wait + stapler       (app)
  ├─ scripts/make-dmg.sh                      (hdiutil; app + /Applications symlink)
  ├─ notarytool submit --wait + stapler       (dmg)
  └─ scripts/gen-appcast.sh                   (sha256 + ed25519 → appcast.json)
```

Everything is plain shell + Xcode tools. No Sparkle, no create-dmg, no Python at release time
beyond `/usr/bin/python3` for JSON.

## One-time setup (Liam)

1. **Developer ID Application certificate** — team `M8ZP994J4T` already exists.
   Xcode → Settings → Accounts → Manage Certificates → "+" → *Developer ID Application*.
   Confirm with `security find-identity -v -p codesigning | grep "Developer ID Application"`.
   (Or create it at developer.apple.com → Certificates and double-click the `.cer`.)

2. **Notary credentials** — an app-specific password for your Apple ID
   (appleid.apple.com → Sign-In and Security → App-Specific Passwords), stored once as the
   keychain profile `navi`:
   ```
   xcrun notarytool store-credentials navi --apple-id <you@icloud.com> --team-id M8ZP994J4T
   ```
   `xcrun notarytool history --keychain-profile navi` should then list (nothing) without error.

3. **Update signing key** — an ed25519 key pair. The private half signs `appcast.json`; the
   public half is compiled into `Navi/App/Updater.swift` (`UpdateVerifier.publicKeyBase64`).
   The key was generated on this Mac at **`~/.config/navi-release/update-key.pem`** and the
   matching public key is already in `Updater.swift`. **Back that file up** (1Password /
   iCloud Keychain secure note): without it no shipped Navi will accept an update.
   To generate elsewhere (or rotate):
   ```
   mkdir -p ~/.config/navi-release && chmod 700 ~/.config/navi-release
   openssl genpkey -algorithm ed25519 -out ~/.config/navi-release/update-key.pem
   chmod 600 ~/.config/navi-release/update-key.pem
   openssl pkey -in ~/.config/navi-release/update-key.pem -pubout -outform DER | tail -c 32 | base64
   ```
   Paste the last line's output into `UpdateVerifier.publicKeyBase64`. Rotation: ship one
   release signed with the *old* key whose binary carries the *new* public key; only then
   switch signing to the new key.

4. **Hosting** — `appcast.json` at `https://navi.app/appcast.json` and DMGs under
   `https://navi.app/downloads/`. With the `web/` Next.js deploy: put both in `web/public/`
   (`web/public/appcast.json`, `web/public/downloads/Navi-<v>.dmg`) and deploy. The DMG can
   instead live on a GitHub Release; then pass `NAVI_DOWNLOAD_BASE` (below) so the appcast
   URL points there. The feed URL is fixed in the app (`NaviSettings.updateFeedURL`).

5. Tools on the release Mac: Xcode 26, `brew install xcodegen uv`.

## Cutting a release

1. Bump `CFBundleShortVersionString` (semver, e.g. `0.2.0`) and `CFBundleVersion`
   (monotonic integer) in `project.yml`, commit on `main` via a PR (Liam merges everything
   through PRs).
2. Write `RELEASE_NOTES.txt` (plain text; it is shown verbatim in the update window).
3. Run:
   ```
   NAVI_DOWNLOAD_BASE=https://navi.app/downloads scripts/release.sh --notes RELEASE_NOTES.txt
   ```
   Add `--universal` for Intel Macs (cross-installs the x86_64 Python tree with uv).
   Takes a few minutes; most of it is notarization (`--wait`).
4. Upload `build/release/Navi-<v>.dmg` and `build/release/appcast.json` to the hosting
   location. Check `curl -s https://navi.app/appcast.json | python3 -m json.tool`.
5. Verify from a *different* user account or Mac: download the DMG in Safari, drag to
   /Applications, open — no Gatekeeper warning beyond the standard "downloaded from the
   internet" dialog. `spctl --assess --type execute -vv /Applications/Navi.app` says
   `accepted source=Notarized Developer ID`.
6. Tag: `git tag v<version> && git push --tags`.

Environment knobs: `NAVI_SIGN_IDENTITY` (default `Developer ID Application`),
`NAVI_NOTARY_PROFILE` (default `navi`), `NAVI_UPDATE_KEY` (default
`~/.config/navi-release/update-key.pem`), `NAVI_DOWNLOAD_BASE`.

### Dry run (no certificate, no notary)

```
scripts/release.sh --dry-run
```
Signs ad-hoc (or with whatever the keychain has), skips notarization, still produces the
DMG and a signed `appcast.json` — the same artifacts, minus Gatekeeper acceptance on other
Macs. `scripts/install.sh --release` runs this and installs the app out of the DMG, so the
bundled browser runtime gets exercised locally. `scripts/dev/runtime-smoke.sh` then proves
the runtime works with the repo checkout hidden.

## What ships inside the app

`Navi.app/Contents/Resources/browser-runtime/` (built by `scripts/bundle-runtime.sh`,
cached under `build/runtime/`):

| Path | What |
|---|---|
| `python-arm64/` (+ `python-x86_64/`) | python-build-standalone CPython 3.12 (`install_only`, pinned tag + SHA-256 checked), stdlib trimmed (no test/tkinter/idle), deps from `vendor/jev-ultrafast/uv.lock` installed into its site-packages, `jev_ultrafast` copied from `vendor/` |
| `navi_runner.py` | `scripts/ultrafast/navi_runner.py` |
| `bin/doctor.sh`, `bin/approve.sh` | Chrome status / approval helpers; take the interpreter from `$NAVI_PYTHON` |
| `manifest.json` | versions, archs, build date |

`UltrafastBridge` resolves the runtime as **bundled → repo checkout → not installed**
(`NAVI_DISABLE_BUNDLED_RUNTIME=1` / `NAVI_DISABLE_REPO_RUNTIME=1` skip a source). The
bundled interpreter runs with `-I -B` and `PYTHONDONTWRITEBYTECODE=1`: the bundle is sealed
by the code signature, so bytecode is precompiled (`compileall --invalidation-mode
unchecked-hash`) and never written at runtime. Chrome is **not** bundled — browser-harness
drives the user's installed Google Chrome over CDP.

Debug builds skip the runtime phase and keep using `vendor/jev-ultrafast/.venv`
(`scripts/ultrafast/setup.sh`). `NAVI_SKIP_RUNTIME=1` skips it for a Release build too.

## Signing details

- Release config (`project.yml`): `CODE_SIGN_IDENTITY: "Developer ID Application"`,
  `ENABLE_HARDENED_RUNTIME: YES`. `scripts/build.sh` downgrades the identity to Apple
  Development / ad-hoc when the certificate is absent so `scripts/install.sh` keeps working.
- Entitlements (`Navi/Navi.entitlements`, generated from `project.yml`): no sandbox
  (Accessibility, ScreenCaptureKit and Apple Events need it off), `automation.apple-events`,
  `network.client`, `device.audio-input` (microphone under the hardened runtime). The Python
  runtime needs no hardened-runtime exceptions — verified: every Mach-O signed with
  `--options runtime`, all imports plus `ctypes`/`ssl` work.
- Switching from the Apple Development identity to Developer ID changes the app's designated
  requirement: on the dev Mac, TCC grants (Accessibility, Screen Recording) and the Keychain
  ACL prompt once after the first Developer ID build.

## In-app updater (`Navi/App/Updater.swift`)

- 30 s after launch and every 24 h: `GET appcast.json`. Menu bar → "Check for Updates…"
  forces a check and also reports "up to date".
- `version` newer than the running `CFBundleShortVersionString` (semantic compare) and not
  skipped → floating "Navi X is available" window with the notes.
- Install: download DMG → verify SHA-256 **and** ed25519 → `hdiutil attach -nobrowse` →
  `ditto` Navi.app to a temp dir → detach → a detached `/bin/sh` waits for the app to quit,
  swaps `/Applications/Navi.app`, `lsregister`s it and `open`s it. If the bundle's folder is
  not writable, the staged app is revealed in Finder instead.
- Off switch: `defaults write com.liamcarlin.navi updateChecksEnabled -bool NO`.
  Test feed: `defaults write com.liamcarlin.navi updateFeedURL http://localhost:8000/appcast.json`
  with `python3 -m http.server` in `build/release/`.

## Rollback

Updates are pull-based, so rolling back is publishing an older-but-higher version:
1. Re-run `scripts/release.sh` from the last good commit with a **bumped** version
   (e.g. `0.2.1` → the good `0.2.0` code as `0.2.2`); installed apps only move forward.
2. Or, faster: replace `appcast.json` with the previous one — nobody who has not yet
   updated will be offered the bad build (those who did keep it until step 1 ships).
3. The DMG of every release stays under `downloads/`; never overwrite a version's file —
   its SHA-256 and signature are in the appcast that people already fetched.
