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

4. **Hosting — GitHub Releases (default, nothing to set up).** `LiamCarlin/Navi` is public,
   so release assets are downloadable by anyone, served from GitHub's CDN, with no domain,
   no bandwidth bill and no 100 MB-per-file deploy limit to worry about:

   | What | URL |
   |---|---|
   | DMG of a version (the appcast's `url`) | `https://github.com/LiamCarlin/Navi/releases/download/v<version>/Navi-<version>.dmg` |
   | Update feed (compiled into the app as `NaviUpdateFeedURL`, project.yml) | `https://github.com/LiamCarlin/Navi/releases/latest/download/appcast.json` |
   | **Download button on the website** (always the newest) | `https://github.com/LiamCarlin/Navi/releases/latest/download/Navi.dmg` |

   `/releases/latest/` only ever resolves to a *published*, non-prerelease release, so a draft
   is invisible to installed copies until you press Publish. `scripts/publish-release.sh`
   uploads all three files as a draft. Another repo: `NAVI_RELEASE_REPO=owner/name` for both
   scripts (and change `NaviUpdateFeedURL` in project.yml).

   **Later, on the website** (once `web/` has a domain): serve the feed from the site —
   either copy `appcast.json` into `web/public/appcast.json` on each release, or (better, no
   redeploy per release) add a redirect in `web/next.config.ts` from `/appcast.json` and
   `/download` to the GitHub `latest/download/…` URLs. Then set `NaviUpdateFeedURL` to
   `https://<domain>/appcast.json` in project.yml. Keep the DMGs on GitHub either way —
   Vercel deployments are a poor place for 30–70 MB binaries.

5. Tools on the release Mac: Xcode 26, `brew install xcodegen uv gh`, `gh auth login`.

## Cutting a release

1. Bump `CFBundleShortVersionString` (semver, e.g. `0.2.0`) and `CFBundleVersion`
   (monotonic integer) in `project.yml`, commit on `main` via a PR (Liam merges everything
   through PRs).
2. Write `RELEASE_NOTES.txt` (plain text; it is shown verbatim in the update window).
3. Run:
   ```
   scripts/release.sh --notes RELEASE_NOTES.txt
   ```
   Add `--universal` for Intel Macs (cross-installs the x86_64 Python tree with uv).
   Takes a few minutes; most of it is notarization (`--wait`). It ends with either
   "Shippable." or a list of exactly what is missing (certificate, notary profile, update
   key, notarization).
4. Upload: `scripts/publish-release.sh` → a **draft** release `v<version>` with
   `Navi-<v>.dmg`, `Navi.dmg` (same file, for the stable download link) and `appcast.json`.
   It refuses a build that is not notarized or an unsigned appcast. Open the draft on GitHub,
   check it, press **Publish release** (or rerun with `--publish`). Then:
   `curl -sL https://github.com/LiamCarlin/Navi/releases/latest/download/appcast.json | python3 -m json.tool`
5. Verify from a *different* user account or Mac: download the DMG in Safari, drag to
   /Applications, open — no Gatekeeper warning beyond the standard "downloaded from the
   internet" dialog. `spctl --assess --type execute -vv /Applications/Navi.app` says
   `accepted source=Notarized Developer ID`. Then the smoke tests in
   `docs/LAUNCH_CHECKLIST.md` § 6.
6. Tag: `git tag v<version> && git push --tags` (the release already created the tag on
   GitHub; `git fetch --tags` is enough if you prefer).

Environment knobs: `NAVI_SIGN_IDENTITY` (default `Developer ID Application`),
`NAVI_NOTARY_PROFILE` (default `navi`), `NAVI_UPDATE_KEY` (default
`~/.config/navi-release/update-key.pem`), `NAVI_RELEASE_REPO` (default `LiamCarlin/Navi`),
`NAVI_DOWNLOAD_BASE` (default `https://github.com/$NAVI_RELEASE_REPO/releases/download/v<version>`).

### Dry run (no certificate, no notary)

```
scripts/release.sh --dry-run
```
Signs ad-hoc (or with whatever the keychain has), skips notarization, still produces the
DMG and a signed `appcast.json` — the same artifacts, minus Gatekeeper acceptance on other
Macs — and lists what is missing for a real release. Verified 2026-10-01 on this Mac (no
Developer ID certificate): Release build → 30 MB DMG with the bundled runtime → appcast
signed with the key that matches `Updater.swift`. `scripts/install.sh --release` runs this
and installs the app out of the DMG, so the bundled browser runtime gets exercised locally.
`scripts/publish-release.sh --dry-run --allow-unsigned` shows what would be uploaded.

`scripts/dev/runtime-smoke.sh` proves the bundled runtime works with the repo checkout
hidden — and, with `--cloud <url> --token <access token>`, that it works the way a
customer's Mac runs it, with no vendor key at all:

```
cd cloud && MOCK_UPSTREAM=1 DEV_LOGIN_SECRET=dev npm run dev        # terminal 1
TOKEN=$(curl -s -X POST localhost:3100/auth/dev-login -H 'content-type: application/json' \
        -H 'x-dev-login-secret: dev' -d '{"email":"smoke@example.com","trial":false}' \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["accessToken"])')
scripts/dev/runtime-smoke.sh build/release/Navi.app --cloud http://localhost:3100 --token "$TOKEN" \
  --url 'data:text/html,<title>Navi smoke</title><button>A</button><button>B</button>'
```
(`scripts/dev/mock-cloud.py --port 8787` instead logs every request's feature/run/bearer.)
The canned mock answers click the first button until the step limit — the point is that
every `/v1/jev` and `/v1/claude` call arrives with the bearer, `X-Navi-Feature: task` and
one `X-Navi-Run`, and `/v1/me` counts exactly one task.

## Browser runner credentials (Navi Cloud)

The bundled runner never sees a vendor key on a customer's Mac. `UltrafastBridge` passes it:

| Variable | Value |
|---|---|
| `NAVI_JEV_TRANSPORT` | `navi` |
| `NAVI_CLOUD_URL` | `CloudTransport.baseURL` (`cloudBaseURL` default, else the build's `NaviCloudBaseURL` Info.plist key, else `https://api.navi.app`) |
| `NAVI_CLOUD_TOKEN` | `CloudTransport.accessToken(validFor: 20 min)` — refreshed first through the shared single-flight refresher if it would lapse sooner (the refresh token stays in the app) |
| `NAVI_CLOUD_FEATURE` / `NAVI_CLOUD_RUN` | the task's `CloudRun` (`task`, or `voice` for spoken tasks) — the runner's calls are metered as part of that one task |

and strips `TYPESAFE_API_KEY`, `AI_GATEWAY_API_KEY`, `ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL`
and `TEXT_MODEL_*` from the environment. The runner (`scripts/ultrafast/navi_runner.py`,
adaptation 20 — the vendored `jev-ultrafast` is untouched) posts the exact TypeSafe body to
`/v1/jev` and Messages bodies to `/v1/claude`. A 401/402/403/503 from the proxy comes back as
`{"event":"error","code":"signed_out"|"quota_exceeded"|"not_entitled"|…}` and the panel shows
Navi's own message. Developer mode (signed out, keys in Navi → Developer) keeps the old
bring-your-own-key variables. Tests: `NaviTests/RunnerCredentialsTests.swift`,
`scripts/ultrafast/test_navi_cloud.py` (run with any interpreter that has the runtime's
deps, e.g. `build/runtime/aarch64/python/bin/python3.12`).

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

- 30 s after launch and every 24 h: `GET appcast.json` from `NaviUpdateFeedURL` (redirects
  followed — GitHub's `latest/download` is a 302 to its CDN). Menu bar → "Check for Updates…"
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
2. Or, faster: on GitHub, edit the bad release and tick **Set as a pre-release** (or delete
   it): `/releases/latest/` falls back to the previous release, so its `appcast.json` is
   served again — nobody who has not yet updated is offered the bad build (those who did
   keep it until step 1 ships).
3. Every release's DMG stays on its own release; never re-upload a version's file — its
   SHA-256 and signature are in the appcast that people already fetched.
