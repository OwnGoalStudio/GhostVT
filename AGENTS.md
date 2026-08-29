# iGhostVT — Agent Notes

Ghostty-powered terminal for jailbroken iOS 15+ — roothide and rootless
bootstraps both. The app renders; the bundled `ighostvtd` LaunchDaemon owns
every spawned process.

## Hard rules

- **No project generators.** `iGhostVT.xcodeproj/project.pbxproj` is
  hand-written and checked in (objectVersion 77, file-system-synchronized
  groups — files added under `iGhostVT/`, `iGhostVTDaemon/`, `Shared/` join
  their target automatically). Never introduce XcodeGen/Tuist/etc.
- **Versions live in `Configuration/Version.xcconfig` only** (edit via
  `make set-version`). xcconfigs attach at project level; a target-level
  `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` in the pbxproj silently
  shadows them and ships the wrong build number. `make check` rejects this —
  keep it that way, and watch for Xcode injecting these keys back.
- **The app never spawns processes.** Only `ighostvtd` forks
  (`forkpty`+`execve`), gated by kernel audit-token peer authentication.
  Keep that boundary; don't add process APIs to the app target.
- Depends on the **released**
  [libghostty-spm](https://github.com/Lakr233/libghostty-spm) package
  (`upToNextMajor` from 1.4.11 — below 1.4.9, `TerminalViewState` publishes
  from inside SwiftUI's update pass; below 1.4.10, a hardware Escape drops
  the keyboard on iOS instead of reaching the shell; below 1.4.11 it does
  the same on Catalyst, where it resigns the terminal and every key after
  it is lost until the next click). Since 1.4.0 the package's
  bare-semver tags are its own release sequence, decoupled from ghostty's;
  the `upstream.X.Y.Z` tags hold the XCFramework binaries. Terminal-library
  changes land in that repo and ship via a new package release — don't
  reintroduce a local path reference to a sibling checkout.

## Layout

FlowDown-style: `iGhostVT/main.swift` (manual `UIApplicationMain`) +
`Application/` (delegates) + `Backend/` (sessions, theme, transport) +
`Interface/<feature>/` + `Resources/`. The daemon mirrors that shape:
`iGhostVTDaemon/main.swift` + `Server/` (listener, peer auth, connections) +
`Session/` (registry, PTY, descriptor I/O) + `Shell/` (what a session runs) +
`System/` (bootstrap paths, C shims) + `Logging/`. Shared XPC protocol in
`Shared/`, transport seam in `Packages/iGhostVTKit`. Both targets use
file-system-synchronized groups, so a new subfolder joins the target on its
own — but `make harness` compiles the daemon by hand and has to find them, so
it globs recursively; keep it that way.

Data flow: one `TabManager` per `UIWindowScene` (owned by `SceneDelegate`);
each `TerminalTab` owns a `TerminalSessionStore`, which drives a
`TerminalTransport`. Daemon sessions outlive the app —
`disconnect()` = detach, `closeSession()` = kill; `DaemonSessionLedger`
persists session IDs so a cold launch reattaches (256 KiB replay).
SSH later = another `TerminalTransport` implementation; don't collapse the
seam.

Quitting is the app's decision, made in `applicationWillTerminate` from the
tabs of every connected scene: a tab whose shell is at its prompt
(`!hasRunningProgram`, the same test that lets its × close without asking)
is killed, a tab with a program running is left in the daemon for the next
launch, and with Keep Alive off everything goes. The kills travel over one
blocking one-shot connection (`XPCDaemonTransport.closeSessionsForQuit`) —
not the tabs' transports, whose `closeSession` is fire-and-forget on a queue
the exit outruns — and the call polls `listSessions` until the closed
sessions are gone, because a close reply only says the SIGHUP was sent. If
that leaves the daemon holding nothing, the Mac build sends `shutdown` and
the launch agent exits; the daemon's only part in this is a `registry.isEmpty`
guard on that one request. Its plist's `KeepAlive` is `{SuccessfulExit =
false}` for exactly this: a crash restarts, the asked-for exit stands, and
`MachServices` demand-launches it the next time the app connects. The device
LaunchDaemon keeps `KeepAlive = true` and is never asked.

A new tab opens where the current one is, and the directory never crosses
the wire: `TabManager.newTab` names the active tab's daemon session
(`inheritDirectoryFrom`, sent with the open only — an attach reaches a shell
that already sits somewhere), and `SessionRegistry` reads *that shell's*
current directory from the kernel (`proc_pidinfo` / `PROC_PIDVNODEPATHINFO`
on the child, not the foreground program) and `chdir`s the new child there
before `execve`. Nothing is typed into a PTY, the app picks no path, it works
for a shell with no OSC 7, and the kernel's spelling is the one `chdir`
wants, whatever vocabulary a vroot-linked shell prints. A directory the
session user can no longer enter falls back to the plan's home, never to
launchd's `/`. The iOS SDK ships no `proc_info.h`, so the struct's ABI lives
as constants in `ProcVnodePathInfo`.

Tab titles have three sources, in this order. The daemon is the primary: each
session polls `tcgetpgrp` on its PTY (and re-checks as output drains, rate
limited — the drain sees one check per 64 KiB otherwise),
resolves the foreground process group leader's `proc_name`, and pushes it as
event 102 — also stated in every open/attach reply — so
`TerminalTab.displayTitle` is a short stable name ("zsh", "vim", "grok") no
matter how often the program retitles. Ghostty's shell integration is the
second: the daemon injects it (`ShellIntegration`) and the .deb ships
libghostty's own scripts to `/usr/share/ighostvt/shell-integration`, so the
shell reports OSC 2 (command), OSC 7 (cwd), OSC 133 (prompts) by itself.
That injection reaches zsh, fish, and bash (which gets `--posix` in argv —
the daemon always spawns the shell directly, see the pam_launchd gotcha
below); a shell invoked as `sh` gets none. For it, `CommandTitleTracker` infers a title
from the line the user typed, and only if it was echoed to the screen — the
check that keeps a password out of the tab bar. The reported (or inferred)
title, trailing whitespace trimmed, is the *secondary* line
(`TerminalTab.secondaryTitle`) under the process name. Because all of these
live on *other* observable objects, the tab has to republish their changes
or no SwiftUI view redraws.

Every presentation of a tab — strip chip, title capsule, sidebar row, switcher
card — carries the same `TabContextMenu` (copy the page as text or image,
export it, lock, close). Close asks first only when it would interrupt
something: event 102 also says whether the foreground process group *is* the
spawned shell (`tcgetpgrp == childPID`, `foregroundIsShell`), and a connected
tab whose shell is at its prompt closes on the spot (`hasRunningProgram`). A
detached tab's last report is stale, so it still asks; an unknown state reads
as running. The two locks freeze the *user*, never the program:
output keeps flowing and the surface keeps rendering. Both live on
`LockableTerminalView`, the app's `TerminalView` subclass installed through
the library's `makePlatformView` seam — refusing `hitTest` and first responder
closes every input path at once, which SwiftUI modifiers could not. That
factory closure reads the tab, because a view is made whenever the surface
mounts and one born after the user locked the tab would otherwise come up
unlocked.

The keyboard lock has to be enforced at the *input view*, not at the tap that
toggles it. libghostty becomes first responder from several other places — the
long-press selection menu, a pointer click, and the host's own `requestFocus`
after any sheet dismisses — and each of those raised the keyboard again while
the lock was on. Handing UIKit an empty `inputView` (and a nil
`inputAccessoryView`) closes all of them at once and keeps first-responder
status, so hardware keys still arrive. Empty the `inputAssistantItem` groups
along with it: the iPad shortcuts bar is not part of `inputAccessoryView`, and
it stays floating over the terminal with a dictation button, costing 40pt of
grid.

Every keyboard shortcut is a `UIKeyCommand` in the main menu — `AppMenus`,
installed from `AppDelegate.buildMenu` — never a SwiftUI `keyboardShortcut`.
One list feeds both the Mac's menu bar and the iPad's hold-⌘ overlay, and it
is where the system's own File ▸ New (⌘N, a window) and Close (⌘W, the
window) are replaced: in a tabbed terminal both keys belong to the tab.
`TerminalWindow` answers the commands, because the window is the one
responder every key passes through (sheets and the switcher included), and
its `canPerformAction` is what greys an item out — a command that would act
on whatever sits under a modal reads as disabled instead of failing quietly.
Bindings follow Terminal.app and Safari for tabs (⌃Tab, ⇧⌘\, ⌘1–9, ⌃⌘S for
the sidebar) and Ghostty for the terminal (⌘+ ⌘− ⌘0, ⌘K); where two
conventions coexist the second key is a hidden alias of the same action.
Close Tab is ⌘W alone — ⌘⌫ was tried as an alias and taken back, because in
a terminal it is delete-to-line-start (readline's ⌘⌫ on the Mac). The
font commands run ghostty's own `increase_font_size` actions on the active
surface and step `TerminalFontSize` alongside — they pre-empt the ⌘+/⌘−
press the library would otherwise have forwarded to ghostty itself. Menu
titles are hand-entered in `Localizable.xcstrings` (eleven languages,
`extractionState: manual`), and two keys made of the same words collide in
the catalog's generated symbols, which is why the menu's entry is keyed
`Settings… (menu)`.

## Build & verify

- `make check` — project/packaging validation
- `make test` — the PTY harness (`make harness` runs the daemon's spawn path
  on macOS; launchd itself is device-only)
- `make deb` — unsigned iphoneos build, ldid ad-hoc sign, roothide
  `iphoneos-arm64e` package; `make deb-rootless` packages the same binaries
  under `/var/jb` as `iphoneos-arm64` (`PACKAGE_FLAVOR` picks the layout)
- `make mac-run` — the whole stack on a Mac: builds `ighostvtd` for macOS and
  loads it as a per-user LaunchAgent (`make mac-daemon`, undone by
  `make mac-daemon-uninstall`; log in `~/Library/Logs/ighostvtd.log`), builds
  the app as Mac Catalyst (`make mac-app`), opens it. This is the off-device
  loop: the Simulator has no daemon, so nothing connects there. Device-only
  behaviour (the GPU entitlement, the bootstrap layouts, privilege drop,
  Live Activities, the software keyboard's accessory bar) is still debugged
  on the jailbroken device with the installed deb.
- `make mac-zip` — the *distributable* Mac build, a separate path from
  `make mac-run` (`mac-zip-check` validates its inputs; `Scripts/package-mac.sh`
  stages, signs, zips). Universal Release, ad-hoc signed by default, Developer
  ID and notarization optional via `MAC_ZIP_IDENTITY` / `MAC_NOTARY_PROFILE`.
  It deliberately does **not** depend on `make check`: that target requires the
  jailbreak toolchain, and a Mac with only Xcode has to be able to cut this zip.

The macOS product is one bundle carrying both programs — `Contents/MacOS/`
holds the Catalyst GUI and `ighostvtd`, and
`Contents/Library/LaunchAgents/wiki.qaq.ighostvtd.plist` (`BundleProgram`, not
`ProgramArguments`) is registered on first launch by `MacLaunchAgent` through
`SMAppService`. The two agent plists in `Packaging/macOS/` are not
interchangeable: the `@DAEMON@` one is the harness sidecar `make mac-run`
installs into `~/Library/LaunchAgents`, the `.agent.` one ships inside the
bundle. They share the label `wiki.qaq.ighostvtd`, so a stale harness job makes
`SMAppService` answer `kSMErrorInvalidSignature` — run
`make mac-daemon-uninstall` before testing a zip.

Gotchas that bit us:

- **The Mac app cannot be sandboxed, and neither can its helper.** macOS 14.2's
  Background Task Management refuses to let a sandboxed app register an
  unsandboxed `SMAppService` job, and the helper cannot be sandboxed either —
  it `forkpty`/`execve`s the user's shell, and children inherit the job's
  sandbox, so every command the user ran would inherit it too. This is not a
  flag to flip if something breaks; it is unsupported. Both
  `Packaging/macOS/*.entitlements` are empty dicts, `mac-zip-check` fails if
  `com.apple.security.app-sandbox` appears in either, and the hardening comes
  from Hardened Runtime (`codesign --options runtime`) instead.
- **Login Items binds to the path the app registered from.** A first launch out
  of Downloads registers a Gatekeeper-translocated mount that is gone by the
  next launch. `MacLaunchAgent` refuses to register outside `/Applications`
  and the window's alert offers to move the app there itself (Move or Quit;
  `moveToApplications()` moves or copies the translocation *original*,
  strips its quarantine flag so the copy is not translocated again, and
  launches it through `NSWorkspace` with `createsNewApplicationInstance`
  before this instance exits) — do not "fix" that by registering anyway.
  Dragging the app to the Trash does not unregister the agent either; the
  app offers no Turn Off of its own (registration is automatic on every
  launch) and Settings ▸ Advanced points at Login Items in System Settings,
  the system's own control, for removal. **Replacing the bundle in place (an
  update, a reinstall) breaks the registration, and `register()` alone
  cannot mend it.** Background Task Management stores a launch constraint
  with the item, and for an ad-hoc signed helper (no Team ID) it pins that
  build's cdhash. The next spawn of the new helper — at login, or from the
  updated app's own `register()`, which reuses the item — dies to AMFI
  (`Launch Constraint Violation`, an `ighostvtd` crash report with
  `SIGKILL (Code Signature Invalid)`), launchd removes the service, and
  BTM's `invalidateLaunchItem` ten seconds later leaves a job whose program
  is the unresolved relative `Contents/MacOS/ighostvtd`, retried every ten
  seconds ("Could not find and/or execute program") until something
  discards the item; a relaunch changes nothing. `SMAppService.status`
  reads `.enabled` throughout. `MacLaunchAgent` therefore fingerprints the
  bundled helper (SHA-256, recorded on each successful `register()`) and
  does `unregister()` + `register()` whenever the helper in the bundle is
  not the one it registered — a missing record counts, so an update from a
  build without the check repairs itself once. Do not replace this with a
  plain re-register, and do not key it on the version: a locally cut zip
  can carry the same version as the one it replaces.
- **A drop pastes a path the shell can use, and where that path comes from
  depends on where the item lives.** `TerminalDropDelegate` replaces the
  library's drop interaction on both platforms (it has to *replace* the
  interaction rather than override the method: `dropInteraction(_:performDrop:)`
  is `public`, not `open`). A Finder drag on Catalyst pastes the item's own
  path, opened in place — a folder as readily as a file. A Files drag on iOS
  has no path a shell in another process could open, so the item (folder
  included) is copied under `TerminalFileStaging.directory` and that path
  is pasted. Data with no file behind it (Photos, a Mail attachment, an image
  off a web page) is written there too, named for its UTType so the path
  carries a real extension. Links and text snippets paste as text. The
  library's own staging API is internal, so the copy lives in the app; only
  the directory and the stale sweep are shared with pastes.
- **The Mac window's blur is AppKit's, reached through the ObjC runtime.**
  `CatalystWindowChrome.install()` (called from `main.swift`, before any
  scene) hooks `UINSApplicationDelegate didCreateUIScene:` and slides an
  `NSGlassEffectView` (macOS 26) / `NSVisualEffectView` (sidebar material,
  behind-window) under the scene view — FlowDown's trick; a
  `UIVisualEffectView` only samples within the window. It shows through
  whatever stays transparent: the window, the hosting controller, and the
  sidebar (no material on Catalyst); the terminal column paints the theme
  itself. The title bar is hidden and `RootView` ignores the top safe area,
  so the top bar rides the window's edge and is the title bar now: the
  traffic lights are moved to its vertical centre (`standardWindowButton:`,
  re-done on every `NSWindowDidResizeNotification`, since AppKit re-tiles
  them), the sidebar keeps a strip of the bar's height above its list, and
  the bar beside a hidden sidebar starts after `windowControlsWidth`. The
  lights' geometry is *screen* points and gets converted: the iPad-idiom
  Catalyst app draws at 77%, so a UIKit inset sized in the app's own points
  lands 23% short of the lights. `WindowDragRegion`,
  behind the bar and the sidebar's strip and footer, moves the window from
  bare chrome (`performWindowDragWithEvent:` on `NSApp.currentEvent`).
- `SMAppService` is `macCatalyst(16.0)`, above this app's iOS 15 deployment
  target, so every call sits behind `#available`. The packager raises the
  staged bundle's `LSMinimumSystemVersion` to 13.0, since a Catalyst app built
  for iOS 15 otherwise advertises macOS 12, where none of this exists and the
  terminal would simply never connect.

- **The PTY's winsize must be the *last* grid the surface reported, and
  only the relay's record of that grid may ever be re-sent.** Reports come
  off ghostty's IO thread; the transport queue, the main actor (`Task`), and
  the daemon's open/attach reply each see them at their own pace.
  `TransportRelay` keeps the record under the lock the reports take, primes a
  freshly installed transport with it, and replays it from the transport's
  `.connected` event — synchronously, on the transport's queue, before the
  hop to the main actor — so a size reported during the round trip lands
  behind the open or attach. The transport itself never replays a size; it
  only dedupes against what the daemon already holds. Never re-send a
  main-actor copy: at cold launch that copy trails the IO thread, lands after
  the settled grid, and — because the library reports only *changes* — leaves
  a 49×16 PTY under a 93×32 surface until the next real resize. That 49×16 is
  the surface's birth size before its first `setSize`, not a transient layout.
- A shell inherits both the daemon's resource limits and every descriptor
  that survives `execve`. Keep an explicit launchd `NumberOfFiles` soft limit
  sized for user workloads, and mark every daemon-owned session descriptor
  `FD_CLOEXEC` as soon as it is acquired; otherwise later shells retain older
  PTYs and lose capacity from their own per-process fd limit. The harness
  proves it with `lsof` on a spawned shell.
- **XNU posts `NOTE_EXIT` before the child is waitable.** `proc_exit` fires
  the kqueue note, *then* marks the process `SZOMB` and signals `SIGCHLD`. A
  process dispatch source that reaps exactly once can therefore see
  `waitpid(WNOHANG) == 0` and never try again — a zombie shell and a tab
  that never learns it died. `PTYSession` polls until reaped on every exit
  signal (the note and the PTY's EOF), and `SessionRegistry` sweeps every
  session on `SIGCHLD`, the one notice sent after `SZOMB`. `SIGCHLD` stays
  `SIG_DFL`: `SIG_IGN` auto-reaps and a `waitpid` racing that can block.
- **A Catalyst app cannot carry the client entitlement.** It is an
  iOS-family binary, and macOS refuses to launch one with an entitlement no
  provisioning profile granted ("Launchd job spawn failed"), ad-hoc signed
  or not. The Mac build is signed with no entitlements and the macOS daemon
  authenticates it by uid and `iGhostVT.app/Contents/MacOS/iGhostVT` path
  instead (`PeerAuthenticator`, `#if os(macOS)` only — the device policy is
  untouched).
- libghostty asks the host before a protected clipboard operation (an OSC 52
  read, a write under `clipboard-write = ask`, a paste that paste protection
  flagged) and **denies it silently when nobody answers**. `RootView` attaches
  `ClipboardConfirmation`, which presents each request as an alert; do not
  remove it or programs' clipboard reads and multi-line pastes into
  non-bracketed programs vanish without a trace.
- **Never spawn sessions through the bootstrap's `login`.** Procursus's
  `/etc/pam.d/login` runs `pam_launchd.so`, which moves the session into a
  per-user bootstrap namespace that cannot reach `com.apple.dnssd.service`;
  iOS has no `/etc/resolv.conf` fallback, so the session keeps TCP but loses
  DNS entirely — `curl` says "Could not resolve host" while
  `curl --dns-servers 8.8.8.8` works. Procursus comments that module out of
  `pam.d/sshd`, which is why ssh sessions resolve. The daemon spawns shells
  directly (no PAM) and supplies the env/uid `login` would have.
- Never redeclare C-variadic functions (e.g. `ioctl`) via `@_silgen_name`
  with fixed arity — arm64 puts variadic args on the stack and the call
  silently misbehaves. Use the Darwin overlay.
- **Never hardcode a bootstrap path.** `JailbreakRoot` detects the layout
  from the daemon's own executable path and exposes the three vocabularies:
  `bootstrapPath()` (a file the bootstrap installed), `systemPath()` (a file
  on the untouched iOS filesystem), `resolve()` (either one, as a syscall
  wants it). roothide's programs are vroot-linked so their paths stay
  unprefixed and iOS's are reached via `/rootfs`; rootless programs have
  `/var/jb` compiled in and speak real paths. Prefixing the wrong one is
  *the* bug this type exists to prevent.
- A GUI app ad-hoc signed with ldid MUST carry
  `com.apple.security.iokit-user-client-class` (with `IOUserClient` / the
  AGX + IOGPU + IOSurface + IOAccel leaves, see
  `Packaging/iGhostVT.entitlements`). This is a jailbroken-iOS property, not
  a roothide one — the rootless package needs it just the same. Without it
  the kernel denies the GPU's IOKit user client — `no-sandbox` does NOT cover
  this — Metal can't create a device, and the symptom is a silent black
  terminal: no crash, ghostty logs `error.MetalFailed` / "surface rebuild
  failed", the kernel logs `deny(1) iokit-open-user-client
  AGXDeviceUserClient`.
