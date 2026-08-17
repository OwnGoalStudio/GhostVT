# Architecture

## Repo layout (FlowDown-style)

```
iGhostty/                    the app, one folder-synchronized Xcode group
├── main.swift               UIApplicationMain entry (no @main)
├── Application/             AppDelegate, SceneDelegate
├── Backend/Session/         TerminalTab, TabManager, TerminalSessionStore
├── Interface/               SwiftUI, grouped by feature
│   ├── Main/                RootView, SessionStatusOverlay
│   ├── Bars/                BottomBar (compact), TabStripBar (regular)
│   ├── Sidebar/             SidebarView (iPad tab list)
│   ├── TabSwitcher/         grid switcher with live snapshots
│   ├── Settings/            SettingsSheet (themes, default shell)
│   └── Support/             GlassStyle, StatusDot, KeyboardState
└── Resources/               Assets.xcassets, Info.plist
Packages/iGhosttyKit/         transport layer (the TerminalTransport protocol)
Shared/                      XPC wire protocol, compiled into app + daemon
iGhosttyDaemon/               ighosttyd: the only process that spawns anything
iGhosttyWidgets/              WidgetKit appex: the Dynamic Island Live Activity
ActivityShared/              ActivityAttributes, compiled into app + appex
```

`iGhostty.xcodeproj` is checked in: objectVersion 77 with a
`PBXFileSystemSynchronizedRootGroup` over the `iGhostty/` folder (Info.plist
excluded via membership exception), local package references to
`../libghostty-spm` and `Packages/iGhosttyKit`. Adding a file to the folder
adds it to the target — there is no generator step.

## Ownership (multi-window)

```
SceneDelegate ──owns──> TabManager ──owns──> [TerminalTab]
   (1 per window)          │                    │
                           │                    ├─ TerminalViewState (surface)
UIHostingController        │                    └─ TerminalSessionStore
   └── RootView ──borrows──┘                          ├─ InMemoryTerminalSession
                                                      └─ XPCDaemonTransport
```

- Each `UIWindowScene` gets its own `TabManager` from its `SceneDelegate` —
  windows are independent, like Safari windows. `sceneDidDisconnect` closes
  all of that window's sessions.
- Interface views only borrow the manager (`@ObservedObject`); the single
  writer for tab lifecycle is `TabManager`.
- App-wide state is limited to the default endpoint in `UserDefaults`.
- New windows: ⌘N, or the context menu on the tab-switcher button
  (`UIApplication.requestSceneSessionActivation`).

## Data flow

The terminal never spawns a process. libghostty runs with the `inMemory`
backend: everything the surface would write to a PTY is handed to the host,
and everything the host receives is parsed by the surface.

- Keystrokes → `InMemoryTerminalSession(write:)` → `TransportRelay` →
  `TerminalTransport.send` → the daemon → the PTY.
- PTY output → the daemon pushes it → transport event → main-actor hop →
  `session.receive(_:)` → VT parser → Metal renderer.
- Grid resize → `InMemoryTerminalSession(resize:)` → relay → transport →
  `TIOCSWINSZ` on the daemon's master fd.
- A session connects only after the surface reports its first viewport:
  before that, bytes fed to the session are dropped, and a size-negotiating
  transport (SSH) wants the grid at connect time anyway.

`TransportRelay` exists because the session's write/resize closures are
captured once at init, while the transport is replaced on every reconnect.

## Interface behavior

- All of a window's surfaces stay mounted in one `ZStack` (hidden, not
  removed) so background tabs keep their grid and connection. The pane stack
  keeps one structural position across compact/regular so size-class changes
  never recreate surfaces.
- Compact: Safari-style floating bottom cluster (title capsule: swipe to
  switch tabs, long-press for settings; hides while the keyboard is up).
- Regular: top tab strip; the sidebar replaces the chips when open.
- Liquid Glass (`glassEffect`) on iOS 26+, `.ultraThinMaterial` below,
  wrapped once in `Interface/Support/GlassStyle.swift`.

## Transport contract

`TerminalTransport` is deliberately minimal: `connect` / `send` /
`updateViewport` / `disconnect` plus one `onEvent` stream delivered on a
transport-owned queue. `XPCDaemonTransport` is the only implementation; SSH
lands later as a second. There is no networked transport — the daemon is the
backend, and debugging happens on device.

## The daemon (device I/O)

```
iGhostty.app                          ighosttyd  (LaunchDaemon, root)
  InMemoryTerminalSession               DaemonServer   mach service listener
        │                                     │        wiki.qaq.ighostty.service
  XPCDaemonTransport ──── XPC ──────────► PeerAuthenticator
        ▲                                     │   audit token: entitlement +
        └──── output / sessionExit ──────┐    │   uid + root-owned exec path
                                         │  PeerSession   one per connection
                                         │        │
                                         └── SessionRegistry ── [PTYSession]
                                                                forkpty + execve
```

- **The app cannot spawn.** `ighosttyd` is the only component that creates a
  process. The app's whole vocabulary is `openSession` / `attachSession` /
  `write` / `resize` / `closeSession` over the mach service, and the daemon
  authenticates every peer from its kernel audit token before answering: the
  caller must hold `wiki.qaq.ighostty.client`, run as root or mobile, and *be*
  the installed root-owned app binary. `Scripts/package-deb.sh` asserts the
  signed entitlements on both binaries, including that the daemon does not
  carry the client entitlement.
- **The daemon holds the data.** Sessions live in `SessionRegistry`, not on
  the connection that opened them, so quitting the app detaches instead of
  killing — `disconnect()` is a detach and `closeSession()` is the kill. Each
  session keeps a 256 KiB replay buffer; attaching replays it so the surface
  rebuilds its screen. The registry caps live sessions daemon-wide, because
  sessions outliving their connection means a per-peer limit bounds nothing
  across relaunches.
- **The daemon stays resident.** It used to idle-exit after thirty seconds
  with no peers and no sessions, relying on launchd to demand-launch it again.
  Demand launch does work on device, but the exit cannot be made atomic
  against launchd routing a new connection — and the window is exactly where
  the app lives, since the last shell exiting is what empties the registry and
  opening a new tab is what happens next. `RunAtLoad` + `KeepAlive` instead,
  which also covers the crash that demand launch cannot.
- **Resize works here.** `updateViewport` becomes `TIOCSWINSZ` on the master
  fd, so the shell always lays out at the grid actually on screen.
- The shell is chosen by the app (`Shell.path` in `UserDefaults`, empty means
  "daemon picks") but validated by the daemon: absolute path, existing,
  executable, argument count capped. Anything else is rejected. The path is
  written the way the bootstrap's own programs write one. Under rootless
  either spelling is accepted — `/var/jb/bin/zsh` and the bare `/bin/zsh` a
  user carries over from another jailbreak name the same file.

## Jailbreak layouts

Two are supported, from one set of binaries. They differ only in where the
package installs and how paths are spelled:

| | install root | package architecture |
| --- | --- | --- |
| **roothide** | the jbroot it picked this boot | `iphoneos-arm64e` |
| **rootless** | `/var/jb` | `iphoneos-arm64` |

`JailbreakRoot` works out which one it is running under by stripping its own
install suffix, `/usr/libexec/ighosttyd`, off its own executable path: nothing
left means no prefix, a path that `/var/jb` canonicalises to means rootless
(a rootless bootstrap may hide a randomly named directory behind that
symlink), anything else is a jbroot. No libroothide dependency, no bridging
header, and off-jailbreak everything degrades to identity so the harness runs
on macOS.

Three path vocabularies exist, and mixing them is *the* jailbreak-path bug:

| `JailbreakRoot` | who reads it | roothide | rootless |
| --- | --- | --- | --- |
| `bootstrapPath()` | bootstrap programs, for their own files | `/bin/zsh` | `/var/jb/bin/zsh` |
| `systemPath()` | bootstrap programs, for iOS's files | `/rootfs/usr/bin` | `/usr/bin` |
| `resolve()` | the kernel — `execve`, `stat`, `open` | `<jbroot>/bin/zsh` | `/var/jb/bin/zsh` |

The asymmetry is libvroot: roothide's Procursus binaries are linked against
that compile-time shim, which rewrites their path syscalls so they already
treat the jbroot as `/`. So under roothide the daemon resolves the executable
it hands to `execve` but leaves every path *inside the environment*
unprefixed — prefixing those would resolve the jbroot twice — and reaches the
untouched iOS filesystem through the jbroot's `/rootfs` bridge. A rootless
bootstrap has no shim: `/var/jb` is compiled into its binaries, so they and
the kernel speak the same real paths, and iOS's own `/usr/bin` is just
`/usr/bin`. Either way the fallback `PATH` is the bootstrap's binary
directories followed by the system's — without the second half a session
reaches everything the jailbreak installed and nothing the system ships.

Session startup follows roothide's own terminal
([roothide/NewTerm](https://github.com/roothide/NewTerm)): prefer handing the
session to `login -fpq <user>`, which establishes the utmp entry, login class,
`PATH`, `HOME`, and `SHELL` the way every other terminal on the device gets
them — hence no hardcoded `PATH` on that route. Only when `login` is missing
does the daemon spawn a shell itself, reading `pw_shell` from the
**bootstrap's** `/etc/passwd` (`resolve(bootstrapPath("/etc/passwd"))`, not
libc's system database) and supplying the environment `login` would have.

The session runs as **mobile (501)**, not as the daemon. `ighosttyd` is root, so
a session would inherit root unless told otherwise, but root is the wrong
default to land the user on: `$HOME`, the caches a shell writes, and everything
else under `/var/mobile` belong to 501, and root-owned files left there break
the apps that own them afterwards. `sudo` covers the other direction, and it is
the direction that can be undone.

How the drop happens depends on the route. `login -fpq mobile` setuids itself,
so that route hands over the name and drops nothing. When the app names a shell
explicitly, or `login` is missing, the daemon does it in the forked child:
`fchown` the terminal to the user, then `setgroups`/`setgid`/`setuid`, then
`execve` — bare syscalls only, since nothing else is safe between fork and
exec. Any failure in that sequence is fatal to the child, because exec'ing
anyway would hand over the root shell that was just refused.
- A `.disconnected` event cannot say *why* — a detach, a dropped link, and
  `exit` typed into the shell all produce one. `XPCDaemonTransport.onSessionExit`
  reports the process exiting specifically, with the dead session's id and
  status, so a host persisting ids can forget them at the right moment
  instead of discovering the death through a failed reattach.
- On the app side, `DaemonSessionLedger` persists the IDs of sessions this
  app opened and has not killed. Closing a tab kills its shell
  (`closeSession`) and drops the ID; scene teardown only detaches. The first
  window of a cold launch claims the persisted IDs and recreates one tab per
  live session, which reattaches and replays.

## Packaging (from CocoaInspector)

- `Configuration/Version.xcconfig` is the single version source;
  `make set-version` writes it, the Debian control and .deb filename read it.
- `make deb` builds both targets unsigned for iPhoneOS, ad-hoc signs each
  with ldid against its own entitlements (`Packaging/iGhostty.entitlements`,
  `Packaging/iGhosttyDaemon.entitlements`), verifies the signed entitlements
  and package metadata, then emits the `.deb`:
  `/Applications/iGhostty.app`, `/usr/libexec/ighosttyd`, and
  `/Library/LaunchDaemons/wiki.qaq.ighosttyd.plist`. `postinst` bootstraps the
  daemon, `prerm` boots it out.
- `make deb-rootless` (`PACKAGE_FLAVOR=rootless`) packages the same binaries
  with `/var/jb` in front of those three paths. The prefix is substituted for
  `@PREFIX@` in the launch daemon plist and the maintainer scripts, and the
  packager asserts the plist launches `ighosttyd` from where it was actually
  installed — the daemon recovers its install root from that path, so a
  mismatch would make every bootstrap path it derives wrong.
- `make check` guards the pbxproj's objectVersion (77) so newer Xcode
  doesn't silently rewrite the project format.
