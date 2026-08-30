# iGhostVT

Ghostty-powered terminal for jailbroken iOS — [roothide](https://github.com/roothide)
and rootless bootstraps alike — built on
[libghostty-spm](https://github.com/Lakr233/libghostty-spm)'s terminal core
with a host-managed I/O backend.

The app never spawns a process. `ighostvtd`, a root LaunchDaemon, owns every
terminal session and is the only component that can start one; the app reaches
it over a mach service and is entitled to nothing else. Sessions therefore
outlive the app — quitting detaches, and relaunching reattaches to the shells
still running.

## Layout

| Path                     | Purpose                                                          |
| ------------------------ | ---------------------------------------------------------------- |
| `iGhostVT/`              | The app: `main.swift`, `Application/`, `Backend/`, `Interface/`, `Resources/` |
| `iGhostVTDaemon/`        | `ighostvtd`: the XPC proxy launchd starts                        |
| `iGhostVTIO/`            | `ighostvtd-io`: the child that owns every PTY, buffer, and shell  |
| `iGhostVTDaemonShared/`  | Bootstrap paths, logging, and the proxy ⇄ io wire, in both        |
| `iGhostVTCLI/`           | `ighostvt-cli`: the command-line client for those sessions       |
| `iGhostVTWidgets/`       | WidgetKit appex: the Dynamic Island Live Activity                |
| `Shared/Protocol/`       | XPC wire protocol, compiled into the app, the daemon, and the CLI |
| `Shared/Activity/`       | `ActivityAttributes`, compiled into the app and the appex        |
| `Configuration/`         | xcconfig files; `Version.xcconfig` holds the version number      |
| `Packaging/`             | Debian control, maintainer scripts, ldid entitlements            |
| `Packaging/macOS/`       | Bundled LaunchAgent and the (empty) entitlements for the Mac app |
| `Scripts/`               | xcodebuild wrapper, deb and macOS packagers, versioning          |
| `Tests/`                 | The PTY harness and the CLI screen-renderer tests                |
| `Documents/`             | Architecture notes, research, and `Site/` — the published page   |

`iGhostVT.xcodeproj` is checked in (objectVersion 77, folder-synchronized
groups — adding a file to a synchronized folder adds it to the target).
libghostty-spm is consumed as a released package, not a sibling checkout.
See `Documents/ARCHITECTURE.md` for the ownership and data-flow design,
the jailbreak path rules, and per-window tabs.

## Packaging

```sh
make deb           # unsigned iPhoneOS build, ldid ad-hoc sign, roothide .deb
make deb-rootless  # the same binaries, packaged under /var/jb
make set-version VERSION=1.2.3
```

Requires `ldid` and `dpkg-deb` (Homebrew). Both packages carry the same
`arm64` binaries and differ only in layout: the roothide one declares
`iphoneos-arm64e` and installs `/Applications/iGhostVT.app`,
`/usr/libexec/ighostvtd` and the LaunchDaemon plist unprefixed, for the
bootstrap to relocate into the jbroot chosen at this boot; the rootless one
declares `iphoneos-arm64` and installs the same three paths under `/var/jb`.
`postinst` bootstraps the daemon either way. `ighostvt-cli` ships inside the
app bundle, with `/usr/bin/ighostvt-cli` as a relative symlink to it.

## Command line

`ighostvt-cli` drives the daemon's sessions from a shell — the same sessions
the app's tabs are showing. Every command is one shot; it never attaches, so
it neither takes a session from the app nor takes over your terminal.

```sh
ighostvt-cli list                       # id, foreground process, size, attached, directory
ighostvt-cli capture 1                  # what that session's screen is showing, as text
ighostvt-cli capture 1 --full           # with the scrollback the daemon still holds
ighostvt-cli send 1 text "ls -la" key Enter
ighostvt-cli send 1 key C-c             # key names follow tmux's send-keys
ighostvt-cli new                        # open a session, print its id
ighostvt-cli new -- /bin/sh -l          # or run something other than the shell
ighostvt-cli kill 1
```

On the Mac it is `/Applications/iGhostVT.app/Contents/MacOS/ighostvt-cli`;
symlink it onto your `PATH` if you want it there. Exit codes: 0 success,
1 the daemon refused (no such session), 64 bad usage, 69 no daemon.

## macOS

```sh
make mac-zip       # universal Release, ad-hoc signed → build/Packages/iGhostVT-<version>-macos.zip
```

The Mac build is the same two programs in one bundle. There is no package
manager to install a daemon, so `ighostvtd` ships *inside* the app at
`Contents/MacOS/ighostvtd`, launched by
`Contents/Library/LaunchAgents/wiki.qaq.ighostvtd.plist`, and the app registers
it with `SMAppService` the first time it runs. The helper then moves, updates,
and is deleted with the app instead of leaving an orphan in
`~/Library/LaunchAgents`.

To install: **unzip → drag `iGhostVT.app` to `/Applications` → open it from
there.** The order matters. Login Items binds to the path the app registered
from, and a first launch out of the Downloads folder — where Gatekeeper runs
it from a translocated, disappearing mount — would register a path that is gone
by the second launch. The app checks, and offers to move itself there (or
quit) rather than registering from the wrong place. macOS then asks once to
allow the background item; until that is granted the terminal says so instead
of spinning on "Connecting…". To remove the helper, turn iGhostVT off under
Login Items in System Settings — dragging the app to the Trash does not.

Neither the app nor the helper is sandboxed, and neither can be: macOS 14.2's
Background Task Management rejects a sandboxed app registering an unsandboxed
`SMAppService` job, and a sandboxed helper would hand its container to every
shell it spawns. Both carry Hardened Runtime instead.

Releases are **ad-hoc signed** — CI has no Developer ID — so Gatekeeper will
refuse the download until the quarantine bit is cleared:

```sh
xattr -dr com.apple.quarantine /Applications/iGhostVT.app
```

For a build that needs none of that, sign locally with a Developer ID and
notarize:

```sh
make mac-zip MAC_ZIP_IDENTITY="Developer ID Application: NAME (TEAMID)" \
             MAC_NOTARY_PROFILE=ighostvt-notary
```

Requires macOS 13 or later.

## Tests

```sh
make test          # the PTY harness and the CLI's screen-renderer tests
make harness       # just the daemon's spawn path, on macOS
make mac-run       # the whole stack on a Mac: daemon as a LaunchAgent + Mac Catalyst app
```

The harness covers what is hardest to debug on a device: `forkpty`/`execve`,
the read loop, exit-status decoding, `TIOCSWINSZ`, descriptor hygiene, and the
path resolution of each jailbreak layout. It also drives the two requests the
CLI adds — reading a session's buffer and typing into it without attaching —
and `Tests/CLIRenderer` checks the screen model `capture` renders with. `make mac-run` builds `ighostvtd` for
macOS, loads it as a per-user LaunchAgent (`make mac-daemon-uninstall` removes
it), and opens the app built as Mac Catalyst against it — every part of the
product except what only the device has (GPU entitlement, bootstrap layouts,
Live Activities). Test those on device: run `make deb`, then install.
