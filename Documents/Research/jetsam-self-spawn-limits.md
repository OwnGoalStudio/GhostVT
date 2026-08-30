# Jetsam limits on `ighostvtd` vs. self-spawned children

**Date:** 2026-08-30  
**Device:** iPad8,9 (`J417AP`), iPadOS 18.5 (`22F76`), Darwin 24.5.0 (`xnu-11417.122.4`)  
**RAM:** 5 978 095 616 bytes (~5.57 GiB)  
**Jailbreak:** Dopamine (rootless, `/var/jb`)  
**Question:** does a LaunchDaemon that `fork`s its own children keep a tight jetsam cap on the daemon, while those children are not bound by the same cap?

**Answer:** yes. On this device the daemon is capped at **18 MB**; every session it starts with `forkpty` + `execve` sits at the **system-wide default task limit of 4 608 MB**.

---

## Observation

`ighostvtd` is a root LaunchDaemon. The product rule is that the app never creates a process; only the daemon does, via `forkpty` + `execve` (`PTYSession`). The LaunchDaemon plist does not set `JetsamMemoryLimit`. `ProcessType` is `Interactive`.

The working hypothesis:

1. A daemon with no per-job jetsam override gets the **Daemon** category default, which is **6 MB** on this device.
2. Dopamine multiplies that kernel limit (default **3×**), so the live cap on `ighostvtd` is **18 MB**.
3. Children created by the daemon itself do **not** go through launchd’s `posix_spawnattr_setjetsam_ext()` path, so they do **not** inherit 6 MB or 18 MB.

That hypothesis holds. It is visible in Apple’s jetsamproperties, in launchd, in Dopamine’s documented multiplier, in XNU comments, and in a live `memorystatus_control` query on this device.

---

## How the daemon creates a process

`Packaging/wiki.qaq.ighostvtd.plist` is a classic LaunchDaemon: `UserName = root`, `RunAtLoad`, `KeepAlive`, `ProcessType = Interactive`, a 10 240 soft `NumberOfFiles` limit, no jetsam keys.

`ProcessType = Interactive` is CPU/IO classification (`spawn type = interactive (4)` in `launchctl print`). It does **not** move the job out of the jetsam **daemon** category, and it does **not** give the process an app-class memory ceiling.

Every session is born in `PTYSession.init`: `forkpty`, privilege drop, `chdir`, `execve`. There is no `posix_spawn`, and no `posix_spawnattr_setjetsam_ext()`. That is the whole difference.

---

## Where 6 MB and 18 MB come from

### Stock default: 6 MB

`/System/Library/LaunchDaemons/com.apple.jetsamproperties.J417.plist`:

```text
Version4 / Daemon / Override / Global
  ActiveSoftMemoryLimit     = 6
  InactiveHardMemoryLimit   = 6
  JetsamPriority            = 40
  ThreadLimit               = 32
```

`launchctl print user/501/wiki.qaq.ighostvtd` agrees with that file. It still reports the **pre-hook** values launchd thinks it applied:

```text
spawn type = interactive (4)
jetsam priority = 40
jetsam memory limit (active, soft) = 6 MB
jetsam memory limit (inactive, hard) = 6 MB
jetsamproperties category = daemon
jetsam thread limit = 32
last exit reason = JETSAM_REASON_MEMORY_PERPROCESSLIMIT
```

The last line is already a kill: this boot, `ighostvtd` has been terminated for crossing its per-process limit.

### Jailbreak: 6 MB × 3 = 18 MB

Dopamine 2.2 made the jetsam multiplier configurable. The previous default was 3× everywhere; 2.2 lowered the default to 2×, then 2.2.1 put **3×** back as the default. The hook lives in launchd (`jetsam_hook.c`) and multiplies the limits launchd is about to hand to `posix_spawnattr_setjetsam*`. It does not rewrite the plist, and it does not run on `fork` / `execve`.

So launchd still prints 6 MB, and the kernel ledger on `ighostvtd` is 18 MB.

---

## Live kernel limits

Queried as root with `memorystatus_control(MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES)` (`command = 8`). `task_for_pid` was not available to the probe, so RSS is omitted; the memlimit fields are the ones that matter.

| PID | name | parent | how created | active | inactive |
|-----|------|--------|-------------|--------|----------|
| 54986 | `ighostvtd` | 1 (launchd) | launchd `posix_spawn` | **18 MB, soft** (`attr=0x0`) | **18 MB, fatal** (`attr=0x1`) |
| 54995 | `zsh` | 54986 | `forkpty` + `execve` | **4 608 MB** | **4 608 MB** |
| 54999 | `zsh` | 54986 | `forkpty` + `execve` | **4 608 MB** | **4 608 MB** |
| 55108 | `grok` | 54995 | child of a session shell | **4 608 MB** | **4 608 MB** |
| 55378 | `grok` | 54999 | child of a session shell | **4 608 MB** | **4 608 MB** |

4 608 MB is this device’s system-wide default task footprint (`max_task_footprint_mb`), the same class of ceiling a foreground app gets. It is not “no limit”; it is not 6 MB or 18 MB either.

The 18 MB split matches the stock 6 MB shape after ×3: active **soft**, inactive **fatal**. The daemon can go over 18 MB while it is treated as active (XPC transaction / non-idle band) without an immediate kill, but it becomes a high-water candidate; once inactive, 18 MB is fatal. The recorded `JETSAM_REASON_MEMORY_PERPROCESSLIMIT` is the hard path.

---

## Why `fork` does not keep the daemon cap

Launchd is the only path that stamps a daemon-sized jetsam limit. It looks up JetsamProperties, fills `posix_spawnattr_t` (`psa_jetsam_flags`, `psa_memlimit_active`, `psa_memlimit_inactive`, `psa_priority`), and the kernel applies those in `kern_exec.c` when `POSIX_SPAWN_JETSAM_SET` is set. Dopamine’s multiplier sits on that same call.

A new process from `fork` + `execve` never takes that path.

XNU, xnu-3247 (`bsd/kern/kern_memorystatus.c`), as quoted by Jonathan Levin:

> Posix_spawn'd processes come through this path to instantiate ledger limits.  
> Forked processes do not come through this path, so no ledger limits exist.  
> **(That's why forked processes can consume unlimited memory.)**

XNU, xnu-12377 (same file, `memorystatus_set_memlimits` family):

> Posix_spawn'd processes and managed processes come through this path to instantiate ledger limits.  
> **Forked processes do not come through this path and will always receive the default task limit.**

The older comment is the unlimited-ledger story. The current comment is what this device does: the child is not left without a ledger, it is given `memorystatus_get_default_task_active_limit()`, which is `max_task_footprint_mb` (here 4 608 MB). `GET_MEMLIMIT_PROPERTIES` reports that converted default when `p_memstat_memlimit_active <= 0`.

`execve` after `fork` does not re-apply jetsam attributes unless the caller passed spawnattr with `POSIX_SPAWN_JETSAM_SET`. `forkpty` cannot express that.

Apple’s own `posix_spawnattr_init` starts jetsam fields at “unset” (`psa_jetsam_flags = 0`, memlimits `-1`). A userspace `posix_spawn` **without** `posix_spawnattr_setjetsam_ext()` is the same as `fork` in this respect: no daemon-sized cap.

---

## What “not controlled” does and does not mean

Children of `ighostvtd` are **not** outside jetsam.

They still:

- have a per-process ceiling (4 608 MB on this iPad)
- can be killed under system-wide pressure, by jetsam band
- share a process **coalition** with the parent by default (`posix_spawn` defaults to inheriting coalitions; `fork` is the same family)

They **are** outside the **daemon 6/18 MB ledger**. A `zsh` or `grok` at hundreds of megabytes does not count against `ighostvtd`’s 18 MB, and will not be killed for crossing 18 MB.

The coupling that remains: the PTY **master** lives in the daemon. If `ighostvtd` is jetsammed, the master fd dies with it, the slave sees EOF / SIGHUP, and the tab is gone even if the child had gigabytes of headroom. `KeepAlive` restarts the daemon; it does not resurrect those PTYs. That is why a fat daemon is still fatal for sessions, while a fat child is not fatal for the daemon.

---

## Implications for this tree

- The 18 MB number is **not** in the plist and must not be hardcoded as if Apple shipped it. It is `Global` 6 MB × Dopamine’s multiplier. A 2× device would show 12 MB; a device with no multiplier would show 6 MB.
- Raising `JetsamMemoryLimit` in the LaunchDaemon plist would raise the **launchd-side** number, which Dopamine would then multiply. That is the supported way to give the daemon more room, not “spawn a helper so the work is uncapped.”
- Moving spawn from `forkpty` to `posix_spawn` with jetsam attrs would **tighten** children to the daemon cap, which is the opposite of a terminal’s needs (the shell and whatever it runs are supposed to be the large processes).
- Replay buffers, log files, and per-session state that live in `ighostvtd` itself are what 18 MB actually constrains. Children already have the relaxed ceiling.

---

## Sources

- This device: `com.apple.jetsamproperties.J417.plist`, `launchctl print user/501/wiki.qaq.ighostvtd`, `memorystatus_control(GET_MEMLIMIT_PROPERTIES)` on live PIDs.
- `iGhostVTDaemon/Session/PTYSession.swift` — `forkpty` + `execve`.
- `Packaging/wiki.qaq.ighostvtd.plist` — no jetsam keys; `ProcessType = Interactive`.
- XNU `bsd/kern/kern_memorystatus.c` (xnu-3247 and xnu-12377): forked processes skip the posix_spawn ledger path.
- XNU `bsd/kern/kern_exec.c`: jetsam attrs applied only when `POSIX_SPAWN_JETSAM_SET`.
- XNU `libsyscall/wrappers/spawn/posix_spawn.c`: spawnattr jetsam fields default unset.
- Jonathan Levin, [No pressure, Mon! Handling low memory conditions in iOS and Mavericks](https://newosxbook.com/articles/MemoryPressure.html).
- Dopamine 2.2 / 2.2.1 changelog: configurable jetsam multiplier, default 3×.
- Apple, [Identifying high-memory use with jetsam event reports](https://developer.apple.com/documentation/xcode/identifying-high-memory-use-with-jetsam-event-reports) — `per-process-limit` vs. `highwater`.
