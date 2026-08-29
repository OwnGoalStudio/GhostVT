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
  (`upToNextMajor` from 1.4.9 — below that, `TerminalViewState` publishes
  from inside SwiftUI's update pass). Since 1.4.0 the package's bare-semver
  tags are its own release sequence, decoupled from ghostty's; the
  `upstream.X.Y.Z` tags hold the XCFramework binaries. Terminal-library
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
export it, lock, close). The two locks freeze the *user*, never the program:
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
conventions coexist the second key is a hidden alias of the same action. The
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
  next launch. `MacLaunchAgent` refuses to register outside `/Applications` and
  the overlay asks to be moved instead — do not "fix" that by registering
  anyway. Dragging the app to the Trash also does not unregister the agent,
  which is why Settings ▸ Terminal Helper carries a Turn Off control that
  surfaces what `unregister()` returns. Replacing the bundle in place (an
  update, a reinstall) leaves Login Items saying *enabled* while launchd has
  no job until the next login — `SMAppService.status` reads `.enabled`, so a
  launch that only registered on `.notRegistered` never fixed it. The app
  re-registers on every launch while enabled; the call is idempotent and
  bootstraps the job on the spot.
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
- `SMAppService` is `macCatalyst(16.0)`, above this app's iOS 15 deployment
  target, so every call sits behind `#available`. The packager raises the
  staged bundle's `LSMinimumSystemVersion` to 13.0, since a Catalyst app built
  for iOS 15 otherwise advertises macOS 12, where none of this exists and the
  terminal would simply never connect.

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
