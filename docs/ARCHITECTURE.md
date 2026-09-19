# Navi architecture

Navi is a single macOS process: a menu-bar agent (`LSUIElement`) that owns a
floating `NSPanel` (the ⌘Space UI), a SwiftUI `Window` (the app the user
sees), a global Carbon hotkey, and a background screen-memory service. No
third-party packages; everything is Foundation / AppKit / SwiftUI / Vision /
ScreenCaptureKit / SQLite3.

## Module map

| Directory | Owns | Key types |
|---|---|---|
| `Navi/App` | process lifetime, menu bar, main window | `NaviApp`, `AppDelegate`, `MenuBarLabel`, `AppActivation` |
| `Navi/Core` | shared contracts, settings, keychain, logging, screen capture | `Intent`, `RouteDecision`, `SearchResult`, `ResultOutcome`, `QueryContext`, `AgentRunHandle`/`AgentEvent`, `MemoryHit`, `NaviSettings`, `Keychain`, `ScreenCapture`, `FrontmostProbe`, `NaviServices` + protocols `QueryRouting`, `AnswerProviding`, `ComputerAgentRunning`, `MemoryServicing` |
| `Navi/Providers` | HTTP clients | `JevClient` (TypeSafe System One), `ClaudeClient` (Messages API: SSE streaming + tool loops), `GeminiClient` (optional cheap vision) |
| `Navi/Router` | query → intent → results | `QueryRouter`, `AnswerService`, `AppIndex`, `FileSearch`, `Calculator`, `SystemCommands` |
| `Navi/Panel` | the ⌘Space UI | `PanelController` (NSPanel), `PanelViewModel` (state machine), `HotKeyManager`, `Views/NaviPanelView` |
| `Navi/Agent` | computer use | `ComputerAgent` (Claude `computer_toolset_20260801` loop + Jev safety gating), `InputController` (CGEvent/AX), `AgentTools` |
| `Navi/Memory` | screen memory | `MemoryService`, `CaptureScheduler`, `OCR` (Vision), `MemoryStore` (SQLite FTS5), `Digester`, `VaultWriter` (Obsidian markdown), `Recall` |
| `Navi/Settings` | the visible app | `SettingsRootView` (NavigationSplitView), `HomeView`, `GeneralView` + `HotKeyRecorderView`, `ProvidersView`, `PermissionsView`, `MemoryView`, `AgentView`, `UsageView`, `AboutView`, `OnboardingView`; helpers `Permissions`, `LoginItem`, `SpotlightShortcutFix`; `DebugSnapshot` (DEBUG only) |

`NaviServices.bootstrap()` wires the concrete types; everything above the
container talks to the four protocols. Type names and `init` signatures of
`QueryRouter`, `AnswerService`, `ComputerAgent`, `MemoryService`,
`NaviPanelView` and `SettingsRootView` are frozen so workstreams can build in
parallel.

## Process & window model

```text
┌──────────────────────────────── Navi process ─────────────────────────────────┐
│  NaviApp (SwiftUI App)                                                        │
│   ├─ Window("Navi", id: "main") ── SettingsRootView          Dock icon shown  │
│   │      └─ opened via openWindow(id:) from MenuBarLabel     only while open  │
│   ├─ MenuBarExtra (✦)  ── MenuBarMenu                                          │
│   │      └─ MenuBarLabel: alive for the whole process; bridges                 │
│   │         AppKit → SwiftUI: .naviOpenMainWindow ⇒ openWindow(id:"main")      │
│   └─ @NSApplicationDelegateAdaptor AppDelegate                                 │
│          ├─ HotKeyManager  (Carbon RegisterEventHotKey, ⌘Space)                │
│          ├─ PanelController ── NaviPanel (NSPanel, non-activating, .popUpMenu) │
│          │        └─ NSHostingView(NaviPanelView) ── PanelViewModel            │
│          ├─ NaviServices { jev, claude, router, answers, agent, memory }        │
│          └─ URL handler  navi://query?q=…  navi://run?q=…                      │
└───────────────────────────────────────────────────────────────────────────────┘
```

- Activation policy is `.accessory` normally and `.regular` while the main
  window is visible (`AppActivation.showDock` / `hideDockIfNoWindows`, driven
  by `NSWindow.willCloseNotification`).
- The panel is `nonactivatingPanel`: it takes key focus for the text field but
  the previous app stays active, so ⏎ on an app result switches instantly and
  answers don't steal focus.
- `AppDelegate.openMainWindow(section:)` is the single entry point for showing
  the app from AppKit code (panel ⌘,, first launch, `navi://` links). SwiftUI
  windows can't be opened from AppKit directly, so it posts
  `.naviOpenMainWindow`; `MenuBarLabel` — the one SwiftUI view that exists for
  the whole process lifetime — receives it and calls `openWindow(id:)`.

## Data flow

### A keystroke in the panel

```text
 keystroke
    │
    ▼
 PanelViewModel.query = "ma"
    ├──▶ router.instantResults(query, context)        < 5 ms, sync, no network
    │       AppIndex fuzzy match, URL/math detection   ─▶ rows render immediately
    │
    └──▶ debounce ~80 ms ──▶ router.route(query, context)      async
                                  │
                                  ├─ JevClient.ask(state, questions)   70–300 ms
                                  │     state = labelled sections (query, frontmost app,
                                  │             window title, clipboard, recent queries)
                                  │     questions = intent / is_risky /
                                  │                 needs_clarification / wants_memory
                                  │     cache hit ⇒ 0 ms (same state+questions within 120 s)
                                  │
                                  ▼
                            RouteDecision {intent, confidence, probabilities, …}
                                  │
                                  ├─ confidence ≥ threshold ─▶ router.results(decision)
                                  │        re-ranks / replaces rows (files, memory hits…)
                                  └─ confidence < threshold ─▶ keep quick match + "Ask Navi"
```

### ⏎ on a row → `ResultOutcome`

```text
 .dismiss              open app / URL / file, run system command      ─▶ panel hides
 .keepOpen             copied result, toast
 .streamAnswer(stream) AnswerService → ClaudeClient.stream (SSE)      ─▶ answer area grows
 .runAgent(handle)     ComputerAgent.run → AgentRunHandle.events       ─▶ live overlay
 .showResults([…])     memory hits, file lists                         ─▶ list replaced
 .error(msg)                                                            ─▶ inline error
```

### Computer-use loop (Agent)

```text
 task ──▶ ComputerAgent.run
            │  loop (≤ agentMaxSteps):
            │   1. ScreenCapture.captureMainDisplay  → downscale ≤ 1280 px → JPEG
            │   2. ClaudeClient.create(model, tools:[computer_toolset_20260801], messages)
            │   3. for each tool_use: InputController performs click / type / key / scroll
            │        (coords scaled back by 1/downscale factor; needs Accessibility)
            │   4. JevClient.ask(state: step log, questions: is_irreversible /
            │        task_complete / is_stuck)                                  ~100 ms
            │        is_irreversible & mode == askForRisky ⇒ emit .needsApproval, await
            │        prohibited category ⇒ .failed, hand back to the user
            │        task_complete ⇒ .completed(summary);  is_stuck ⇒ .failed
            │   5. append tool_result blocks (toolset_name: "computer") + new screenshot
            ▼
          AgentRunHandle.events  (planned / step / screenshot / needsApproval / status / completed / failed)
```

### Screen Memory pipeline

```text
 CaptureScheduler (every memoryCaptureIntervalSeconds, skipped while paused or excluded app)
    │
    ▼
 ScreenCapture.captureMainDisplay(excludeSelf: true) ─▶ FrontmostProbe (app, title, URL)
    │
    ▼
 OCR (Vision VNRecognizeTextRequest, on-device)
    │
    ▼
 JevClient.ask(state: app + title + url + OCR excerpt,
               questions: activity / is_sensitive / is_new_context / importance)
    ├─ is_sensitive ≥ 0.5 ─────────────▶ dropped (nothing written)
    ├─ importance low & !is_new_context ▶ MemoryStore: OCR text + metadata only (FTS5)
    └─ otherwise ───────────────────────▶ MemoryStore + frame JPEG kept for digest
                                                  │
 Digester (every memoryDigestIntervalMinutes, or "Digest now")
    │  kept frames ─▶ GeminiClient (Flash-Lite) or ClaudeClient.describeImage (Haiku 4.5)
    ▼
 VaultWriter ─▶ <vault>/Daily/YYYY-MM-DD.md, Projects/*.md, Apps/*.md  ([[wiki links]])
 Recall.search(query) ─▶ FTS5 over OCR + digests ─▶ [MemoryHit]  (used by the panel)
 Retention: frames older than memoryRetentionDays pruned; notes kept.
```

### Settings window

```text
 SettingsRootView (NavigationSplitView)
   sidebar: List(selection: SettingsNavigator.shared.section)
   detail:  Home | General | AI Providers | Permissions | Screen Memory | Agent | Usage | About
   sheet:   OnboardingView when !UserDefaults["hasCompletedOnboarding"]

 state:  NaviSettings.shared (@Published, UserDefaults-backed, posts .naviSettingsChanged)
         Keychain (API keys; posts .naviKeysChanged after Save)
         SettingsNavigator.shared (cross-section "Fix" jumps; AppDelegate.openMainWindow(section:))
 polling (only while visible, 2 s): PermissionsModel, LoginItem.status, services.memory.status
 shell-outs (async, off main): SpotlightShortcutFix (defaults export/write, activateSettings -u)
```

## Threading model

| Actor / queue | What runs there |
|---|---|
| **Main actor** | All UI (`PanelViewModel`, `PanelController`, settings views), `NaviSettings`, `AppDelegate`, `HotKeyManager` (Carbon callback hops to main), `instantResults`, `results(for:)`, Apple Events (`NSAppleScript`), `NSOpenPanel`. |
| **Swift concurrency (cooperative pool)** | `JevClient.ask`, `ClaudeClient.stream/create`, `route(query:)`, `MemoryService.search/digestNow`, provider tests, `Shell.run` continuations. Clients are `@unchecked Sendable` value-less wrappers around `URLSession`. |
| **URLSession delegate queues** | SSE byte streams (`bytes(for:)`), token accounting hops to main via `MainActor.run`. |
| **Memory queue** | Capture → OCR → triage runs as a detached task chain; `MemoryStore` serialises SQLite access through an actor. Vision requests execute on their own threads. |
| **Global monitors** | `NSEvent.addGlobalMonitorForEvents` (click-outside dismiss) and `addLocalMonitorForEvents` (panel keys, hotkey recorder) are main-thread callbacks. |

Rules: Swift 5 language mode with `SWIFT_STRICT_CONCURRENCY=minimal`; UI
classes are still annotated `@MainActor`; NotificationCenter / Dispatch
closures use `MainActor.assumeIsolated`. Never block the main actor on Jev —
instant results always render first.

## Permissions

| Permission | Needed by | Probe | Request |
|---|---|---|---|
| Accessibility | `InputController` (CGEvent posting, AX clicks), window titles in `FrontmostProbe`/`ContextProbe` | `AXIsProcessTrusted()` | `AXIsProcessTrustedWithOptions(prompt)` |
| Screen Recording | `ScreenCapture` (agent frames, memory captures), window titles via CGWindowList | `CGPreflightScreenCaptureAccess()` | `CGRequestScreenCaptureAccess()` |
| Automation (Apple Events) | browser tab URL, AppleScript system commands | `AEDeterminePermissionToAutomateTarget(System Events, askUserIfNeeded: false)` | run a trivial `NSAppleScript` against System Events |
| Notifications | task-complete alerts | `UNUserNotificationCenter.notificationSettings()` | `requestAuthorization([.alert,.sound])` |
| Login item | General → Launch at login | `SMAppService.mainApp.status` | `register()` / `unregister()` |

The global hotkey (`RegisterEventHotKey`) needs no permission. Spotlight's
⌘Space is a *conflict*, not a permission: `SpotlightShortcutFix` reads
`com.apple.symbolichotkeys` (key 64 = Show Spotlight search, 65 = Finder
search window), and can disable 64 with `defaults write … -dict-add` +
`activateSettings -u`.

Every subsystem that touches the screen, keyboard or Apple Events checks its
permission first and surfaces "Grant in System Settings" (deep links under
`x-apple.systempreferences:com.apple.preference.security?Privacy_*`).

## Persistence

| Data | Where |
|---|---|
| Settings | `UserDefaults.standard` (`NaviSettings` keys; `hasCompletedOnboarding`) |
| API keys | Keychain, service `com.liamcarlin.navi`, accounts `TYPESAFE_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`, `OPENAI_API_KEY`, `DEEPGRAM_API_KEY`, `FIRECRAWL_API_KEY` |
| Frames, OCR, FTS index | `~/Library/Application Support/Navi/` (`NaviSettings.dataDirectory`) |
| Vault | `memoryVaultPath` (default `~/Navi Vault`) |
| Usage counters | UserDefaults (`usageJevCalls`, `usageClaudeInputTokens`, `usageClaudeOutputTokens`, `usageDigestFrames`) |

## Build

XcodeGen generates `Navi.xcodeproj` from `project.yml` (folder-synced groups,
so new files are picked up automatically). Ad-hoc signing, no sandbox,
hardened runtime off. `scripts/build.sh [Debug|Release] [derived-data-dir]`
wraps `xcodegen generate` + `xcodebuild`; parallel agents pass private
derived-data directories.
