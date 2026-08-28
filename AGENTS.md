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
  (`upToNextMajor` from 1.4.3). Since 1.4.0 the package's bare-semver
  tags are its own release sequence, decoupled from ghostty's; the
  `upstream.X.Y.Z` tags hold the XCFramework binaries. Terminal-library
  changes land in that repo and ship via a new package release — don't
  reintroduce a local path reference to a sibling checkout.

## Layout

FlowDown-style: `iGhostVT/main.swift` (manual `UIApplicationMain`) +
`Application/` (delegates) + `Backend/` (sessions, theme, transport) +
`Interface/<feature>/` + `Resources/`. Daemon code in `iGhostVTDaemon/`,
shared XPC protocol in `Shared/`, transport seam in `Packages/iGhostVTKit`.

Data flow: one `TabManager` per `UIWindowScene` (owned by `SceneDelegate`);
each `TerminalTab` owns a `TerminalSessionStore`, which drives a
`TerminalTransport`. Daemon sessions outlive the app —
`disconnect()` = detach, `closeSession()` = kill; `DaemonSessionLedger`
persists session IDs so a cold launch reattaches (256 KiB replay).
SSH later = another `TerminalTransport` implementation; don't collapse the
seam.

Tab titles have two sources, in this order. Ghostty's shell integration is
the real one: the daemon injects it (`ShellIntegration`) and the .deb ships
libghostty's own scripts to `/usr/share/ighostvt/shell-integration`, so the
shell reports OSC 2 (command), OSC 7 (cwd), OSC 133 (prompts) by itself.
That injection reaches zsh, fish, and bash (which gets `--posix` in argv —
the daemon always spawns the shell directly, see the pam_launchd gotcha
below); a shell invoked as `sh` gets none. For it, `CommandTitleTracker` infers a title
from the line the user typed, and only if it was echoed to the screen — the
check that keeps a password out of the tab bar. `TerminalTab.displayTitle`
picks between them; because both live on *other* observable objects, the tab
has to republish their changes or no SwiftUI view redraws.

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

Gotchas that bit us:

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
