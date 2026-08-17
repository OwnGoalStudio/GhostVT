# iGhostty — Agent Notes

Ghostty-powered terminal for jailbroken iOS 15+ — roothide and rootless
bootstraps both. The app renders; the bundled `ighosttyd` LaunchDaemon owns
every spawned process.

## Hard rules

- **No project generators.** `iGhostty.xcodeproj/project.pbxproj` is
  hand-written and checked in (objectVersion 77, file-system-synchronized
  groups — files added under `iGhostty/`, `iGhosttyDaemon/`, `Shared/` join
  their target automatically). Never introduce XcodeGen/Tuist/etc.
- **Versions live in `Configuration/Version.xcconfig` only** (edit via
  `make set-version`). xcconfigs attach at project level; a target-level
  `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` in the pbxproj silently
  shadows them and ships the wrong build number. `make check` rejects this —
  keep it that way, and watch for Xcode injecting these keys back.
- **The app never spawns processes.** Only `ighosttyd` forks
  (`forkpty`+`execve`), gated by kernel audit-token peer authentication.
  Keep that boundary; don't add process APIs to the app target.
- Depends on a **sibling checkout** of
  [libghostty-spm](https://github.com/Lakr233/libghostty-spm) at
  `../libghostty-spm` (local path package).

## Layout

FlowDown-style: `iGhostty/main.swift` (manual `UIApplicationMain`) +
`Application/` (delegates) + `Backend/` (sessions, theme, transport) +
`Interface/<feature>/` + `Resources/`. Daemon code in `iGhosttyDaemon/`,
shared XPC protocol in `Shared/`, transport seam in `Packages/iGhosttyKit`.

Data flow: one `TabManager` per `UIWindowScene` (owned by `SceneDelegate`);
each `TerminalTab` owns a `TerminalSessionStore`, which drives a
`TerminalTransport`. Daemon sessions outlive the app —
`disconnect()` = detach, `closeSession()` = kill; `DaemonSessionLedger`
persists session IDs so a cold launch reattaches (256 KiB replay).
SSH later = another `TerminalTransport` implementation; don't collapse the
seam.

Tab titles have two sources, in this order. Ghostty's shell integration is
the real one: the daemon injects it (`ShellIntegration`) and the .deb ships
libghostty's own scripts to `/usr/share/ighostty/shell-integration`, so the
shell reports OSC 2 (command), OSC 7 (cwd), OSC 133 (prompts) by itself.
That injection only reaches zsh, fish, and a directly-spawned bash — bash
needs `--posix` in argv, which the `login` route cannot carry, and a shell
invoked as `sh` gets none. For those, `CommandTitleTracker` infers a title
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
- Debugging happens on the jailbroken device (install the deb); there is no
  simulator loop — the Simulator has no daemon, so nothing connects there.

Gotchas that bit us:

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
  `Packaging/iGhostty.entitlements`). This is a jailbroken-iOS property, not
  a roothide one — the rootless package needs it just the same. Without it
  the kernel denies the GPU's IOKit user client — `no-sandbox` does NOT cover
  this — Metal can't create a device, and the symptom is a silent black
  terminal: no crash, ghostty logs `error.MetalFailed` / "surface rebuild
  failed", the kernel logs `deny(1) iokit-open-user-client
  AGXDeviceUserClient`.
