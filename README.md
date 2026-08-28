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

| Path                   | Purpose                                                          |
| ---------------------- | ---------------------------------------------------------------- |
| `iGhostVT/`            | The app: `main.swift`, `Application/`, `Backend/`, `Interface/`, `Resources/` |
| `iGhostVTDaemon/`       | `ighostvtd`: the only process that spawns anything                |
| `Shared/`              | XPC wire protocol, compiled into both targets                    |
| `Packages/iGhostVTKit/` | Transport layer: the `TerminalTransport` protocol                |
| `Configuration/`       | xcconfig files; `Version.xcconfig` is the version's home         |
| `Packaging/`           | Debian control, maintainer scripts, ldid entitlements            |
| `Scripts/`             | xcodebuild wrapper, deb packager, versioning                     |

`iGhostVT.xcodeproj` is checked in (objectVersion 77, folder-synchronized
groups — adding a file to a synchronized folder adds it to the target). The
local `../libghostty-spm` checkout is referenced as a path dependency.
See `Documentation/ARCHITECTURE.md` for the ownership and data-flow design,
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
bootstrap to relocate into the jbroot it picked this boot; the rootless one
declares `iphoneos-arm64` and installs the same three paths under `/var/jb`.
`postinst` bootstraps the daemon either way.

## Tests

```sh
make test          # the PTY harness
make harness       # just the daemon's spawn path, on macOS
make mac-run       # the whole stack on a Mac: daemon as a LaunchAgent + Mac Catalyst app
```

The harness covers what a device test is worst at debugging: `forkpty`/`execve`,
the read loop, exit-status decoding, `TIOCSWINSZ`, descriptor hygiene, and the
path resolution of each jailbreak layout. `make mac-run` builds `ighostvtd` for
macOS, loads it as a per-user LaunchAgent (`make mac-daemon-uninstall` removes
it), and opens the app built as Mac Catalyst against it — every part of the
product except what only the device has (GPU entitlement, bootstrap layouts,
Live Activities). Those are debugged on device: `make deb` and install.
