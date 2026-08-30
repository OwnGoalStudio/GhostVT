# Handoff: the first tab's surface never draws on iPad when the daemon is down at launch

**Date:** 2026-08-31  
**Status:** open — not reproduced off-device; needs one unified-log capture from the iPad  
**Affects:** iPad (jailbroken device). Seen on 0.4.1, 0.4.4, 0.4.9, 0.5.0 — it is **not** a regression from the 0.5.0 resize throttle or libghostty-spm 1.4.12 (every app tag from 0.3.9 to 0.4.9 pins lib 1.4.11 and shows it too). Earlier than 0.4.1 untested.

---

## The symptom, exactly as observed

1. Launch the app while `ighostvtd` is **not yet reachable** (fresh boot before the LaunchDaemon is up, or the daemon otherwise not answering). The first tab is created and its connection waits / fails.
2. The daemon comes up; the tab connects normally: the sidebar dot goes green, the title becomes `zsh`, **typing works, `htop` runs, and event 102 keeps retitling the tab** (`htop` shows in the sidebar). `ighostvt-cli capture` shows the session drawing fine on the daemon side.
3. The pane itself shows **nothing** — and it was empty the whole time: not even the grey `[iGhostVT] Connection lost. Reconnecting…` status lines that `TerminalSessionStore.printStatusLine` feeds into the session *before* the connection succeeds.
4. Resizing the window (Stage Manager) does not fix it. Switching tabs in the sidebar does not fix it.
5. **A brand-new tab opened afterwards renders fine.** So this is not process-wide state (the shared display link, the ghostty runtime, the GPU entitlement): it is *this tab's* surface.
6. Quit and relaunch (daemon now up) → everything is fine.

## What that narrows it to

The visible `UITerminalView` for the first tab **has** a ghostty surface — key encoding needs one, and typing reaches the shell. The session side works. So one of:

- **(A) The session's bytes go to a surface other than the one on screen.** `InMemoryTerminalSession` holds exactly one `ghostty_surface_t` (`InMemoryTerminalSurfaceAccess.setSurface`, replaced on every surface creation that names this session; `clearSurface(ifMatches:)` on teardown is identity-guarded). If SwiftUI ever made *two* platform views for the one `TerminalViewState` (a rebuilt representable, a pane inserted twice during a transition), the session ends up bound to whichever surface was created last, and the visible one never receives output. Input still works from the visible one — it goes *out* through the store, not through the session's surface.
- **(B) The visible surface exists but its coordinator never renders.** `TerminalSurfaceCoordinator.canRenderFrame` = `isDisplayVisible && isApplicationActive && isAttached()`. A view attached while `UIApplication.shared.applicationState != .active` records `isApplicationActive = false` (`syncApplicationActiveState` in `didMoveToWindow`) and only `applicationDidBecomeActive` / `UIScene.didActivateNotification` clears it; a tab whose `TerminalViewState.isSurfaceVisible` was stamped false and never re-stamped true has `isDisplayVisible = false`. Both leave the surface alive and silent. Against (B): a resize calls `synchronizeMetrics`, not `renderImmediately`, so it would not help — consistent with what was seen; but a new tab's coordinator would be fine — also consistent.
- **(C) The surface never got a usable size** (born while the view was zero-sized; `rebuildIfReady` keeps `pendingRebuild` and waits for a layout). Against (C): a later resize would deliver one, and it did not help. Least likely.

The distinguishing fact between (A) and (B) is in the library's lifecycle log, which the app already sends to the unified log — see below.

## What has been ruled out

- **The daemon.** `ighostvt-cli` sees the session working; the proxy/io split (0.4.5) and the CLI admission changes (0.5.0) are not involved. The device packaging (`Scripts/package-deb.sh`) did not touch the app's entitlements — the GPU `iokit-user-client-class` list is still on the app, and a missing one would blank *every* launch, not the first.
- **The 0.5.0 resize throttle** (`TerminalTab.resizeThrottle`, 128 ms until the shell is verifiably at its prompt) and **libghostty-spm 1.4.12** (UIKit layer held at `syncedViewSize` while throttled). Both post-date the bug. Do not spend time there for this issue.
- **Simulator reproductions — all render correctly** (iPad Pro 11-inch (M5) simulator, Debug build of `db359d0`):
  1. Plain launch: no daemon → the reconnect cycle → "Terminal Unavailable" card; the status lines are visible under the card.
  2. `DaemonSessionDirectory.claimResumable` delayed 6 s (emulating the `listSessions` timeout, so the first tab is created well after the scene is active): renders.
  3. A simulator-only fake `TerminalTransport` that emits `.interrupted` on the first connect and `.connected` + `.processName("zsh", isShell: true)` + a prompt on the second: renders, prompt visible.
  4. Same as 3 with the software keyboard enabled (`defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false`): renders.
  So the app-side state machine (failed → connected, late tab creation, the alert card claiming first responder) does not reproduce it on its own. Something in the device's timing or the real daemon's path is required.

## What to capture on the device (the one thing that will settle it)

`AppDelegate` already routes `TerminalDebugLog` (`.lifecycle` + `.metrics`) into os_log — subsystem `wiki.qaq.iGhostVT`, category `ghostty`, lines prefixed `[GhosttyTerminal]`. Nothing needs enabling for those two categories.

Capture one bad launch and one good launch:

- USB + Console.app on the Mac: select the iPad, search `process:iGhostVT`, Start, reproduce, Select All → Copy → save.
- Or over SSH on the device: `log stream --process iGhostVT --style compact > /tmp/ighostvt.log`.
- For input/output tracing on top (logs keystrokes — opt-in): `defaults write wiki.qaq.iGhostVT Debug.verboseTerminalLog -bool true` on the device, or Settings ▸ Advanced ▸ Detailed Terminal Log; relaunch. The `.render` category ("tick" per drawn frame) is not in `.standard`; enable `TerminalDebugLog.enable(.all)` temporarily in `AppDelegate` if frame-level evidence is needed.

Then read, for the first tab, in order:

| Line | What it tells |
| --- | --- |
| `surface rebuild succeeded` / `surface rebuild failed` / `surface rebuild skipped: …` | how many surfaces were made for the tab, and whether any creation failed |
| `in-memory session surface=set` / `surface=nil` / `in-memory session clear skipped expected=… current=…` | which surface the session is bound to; **two `surface=set` for one tab, or a `clear skipped`, is hypothesis (A)** |
| `didMoveToWindow attached=true/false` | attach/detach churn — a detach + reattach pair around the connect is a second-view smell |
| `application did become active` / `application did enter background` | whether the view ever learned the app is active — **`setApplicationActive(false)` with no later active is hypothesis (B)**; note there is no log line for the inactive read in `syncApplicationActiveState` itself, so look for the absence of `display link acquired` after the surface exists |
| `display link acquired` / `display link released` | whether this coordinator ever had a link; a surface that never acquires one never draws |
| `sync view=… pixels=…` / `sync updated …` / `synchronizeMetrics skipped: invalid view size` | whether the surface was ever sized (hypothesis (C)) |
| `wakeup suspended` | the controller refusing ticks because no observer's `shouldProcess` (`isApplicationActive && isAttached()`) held |

Compare with the same lines from the good launch. Time-align with the `session` category lines (`connecting via …`, `connected to …`, `link lost: …`) to see where in the connect cycle the divergence is.

## Reproducing the daemon-down launch on the device

The LaunchDaemon has `KeepAlive = true`, so killing `ighostvtd` only restarts it. Unload the job first, launch the app, then load it again once the app is sitting on its card / pill (paths for rootless carry the `/var/jb` prefix; roothide's `launchctl` is vroot-linked and takes them unprefixed):

```sh
launchctl bootout system/wiki.qaq.ighostvtd
# launch iGhostVT from the home screen, wait for the "Connecting…" pill or the card
launchctl bootstrap system /Library/LaunchDaemons/wiki.qaq.ighostvtd.plist
```

Whether the app is left on the pill (hello queued by launchd until the daemon answers) or reaches the card (the connection errored) is itself worth noting: on the simulator the mach lookup fails instantly and the card appears; on the device the observed behaviour ("empty the whole time") suggests the surface never drew even before any of that.

## Code map for whoever picks this up

App (this repo):

- `iGhostVT/Backend/Session/TabManager.swift` — `init` → `DaemonSessionDirectory.claimResumable` (a `listSessions` with a 6 s timeout; nil → `[]` → `newTab()`); `activeTabID.didSet` → `syncSurfaceVisibility()` (the only writer of `TerminalViewState.isSurfaceVisible`).
- `iGhostVT/Backend/Session/TerminalSessionStore.swift` — `connectWhenReady` (needs the surface's first viewport *and* scene active), `apply(_:)` (the `.interrupted` → `scheduleReconnect` cycle, `printStatusLine` into the session), `TransportRelay`.
- `iGhostVT/Backend/Session/TerminalTab.swift` — one `TerminalViewState` (and therefore one `TerminalController` / ghostty app) per tab; `makePlatformView` → `LockableTerminalView`.
- `iGhostVT/Interface/Main/RootView.swift` — `panes` `ZStack` + `ForEach` → `TerminalPane` → `TerminalSurfaceView(context:)`, `.opacity(isActive ? 1 : 0)`; `refocus()`; `SessionStatusOverlay` (card + `AlertFirstResponder`, 0.4.8).
- `iGhostVT/Application/AppDelegate.swift` — the `TerminalDebugLog.sink` into os_log.
- `iGhostVT/Application/SceneDelegate.swift` — `sceneDidBecomeActive` → `tabManager.noteSceneActive()`.

Library (`../libghostty-spm`, tag 1.4.11 / 1.4.12):

- `Sources/GhosttyTerminal/Surface/TerminalSurfaceCoordinator.swift` — `rebuildIfReady`, `synchronizeMetrics` / `performMetricsSync`, `setDisplayVisible`, `setApplicationActive`, `tick`, `ensureDisplayLink` / `releaseDisplayLink`, `canRenderFrame`.
- `Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+Lifecycle.swift` — `didMoveToWindow` (`syncApplicationActiveState`, rebuild-or-sync, the deferred `fitToSize`), the app-active notification observers, `layoutSubviews`.
- `Sources/GhosttyTerminal/View/TerminalViewRepresentable.swift` + `…@UIKit.swift` — `configureView` (forwards `isSurfaceVisible` only on change via `hostDeclaredDisplayVisible`), `makeUIView` / `dismantleUIView`.
- `Sources/GhosttyTerminal/InMemory/InMemoryTerminalSession.swift` + `InMemoryTerminalSurfaceAccess.swift` — the one-surface binding, `pendingWrites` flushed on `setSurface`.
- `Sources/GhosttyTerminal/Controller/TerminalController.swift` — `handleWakeup` and the per-surface `WakeupObserver`s.
- `MSDisplayLink` 2.2.0 (`DerivedData/SourcePackages/checkouts/MSDisplayLink`) — one shared `CADisplayLink` per process, stopped on `didEnterBackground`, restarted on `willEnterForeground`. Read; nothing found that would silence a single coordinator while another draws.

## Simulator harness used (to re-create quickly)

Build and run: see the `sim-ui-check-loop` recipe — `xcodebuild -project iGhostVT.xcodeproj -scheme iGhostVT -configuration Debug -derivedDataPath /private/tmp/ighostvt-deriveddata -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' -skipMacroValidation -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build`, then `simctl install` / `launch` / `io … screenshot`. Screenshots come out rotated for a landscape iPad; the content is fine.

The fake transport (not committed; ~30 lines, simulator-only): a `TerminalTransport` whose `connect()` emits `.state(.connecting)`, then after 1.5 s either `.state(.interrupted(reason:))` (first attempt) or `.state(.connected)`, `.processName("zsh", isShell: true)`, `.received("…fake$ ")`; `send` echoes; `updateViewport` no-op. Wire it at the top of the `makeTransport` closure in `TerminalTab.init` behind `#if targetEnvironment(simulator)` and a `Debug.experimentTransport` default. The 6 s launch delay is a `try? await Task.sleep(nanoseconds: 6_000_000_000)` at the top of the `Task` in `DaemonSessionDirectory.claimResumable`.

## Next steps

1. Capture the two logs (bad launch, good launch) and diff the first tab's `[GhosttyTerminal]` lines as in the table above. That decides (A) vs (B) vs (C).
2. If (A): find what makes SwiftUI build a second `UITerminalView` for the tab on the device (look at `didMoveToWindow attached=` pairs and `surface rebuild succeeded` counts); the fix is in the app's view structure, or the library's session binding should prefer the view that is attached.
3. If (B): find which of `isApplicationActive` / `isDisplayVisible` is stuck and why the notification or the representable's forwarding never reached that coordinator; the defensive fix is to re-stamp both on `.connected` (and on any resize), the real fix is at whichever path dropped the update.
4. Write the answer into `Documents/ARCHITECTURE.md` / `CLAUDE.md` gotchas once known — this is the third "first terminal of a cold launch sits blank" bug in this stack, and the previous two (the born-occluded surface; the 49×16 PTY) are recorded there.
