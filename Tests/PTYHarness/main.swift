import Darwin
import Dispatch
import Foundation

// Exercises the daemon's spawn path on macOS, where the mach service and
// launchd are out of reach but `forkpty`/`execve`, the read loop, the exit
// decoding, and `TIOCSWINSZ` behave the same as on the device. This is the
// part of the daemon a device test would be worst at debugging, so it gets
// covered here first.

let harnessQueue = DispatchQueue(label: "wiki.qaq.ighostty.harness")
var failures: [String] = []

func check(_ condition: Bool, _ description: String) {
    if condition {
        print("  ok   \(description)")
    } else {
        print("  FAIL \(description)")
        failures.append(description)
    }
}

/// Runs a session to completion, returning everything it printed and how it
/// exited. `input` is written once the session is running.
func run(
    command: [String],
    input: String? = nil,
    columns: UInt16 = 80,
    rows: UInt16 = 24,
    resizeTo: (columns: UInt16, rows: UInt16)? = nil,
    credentials: ShellLaunch.Credentials? = nil,
    workingDirectory: String? = nil,
    timeout: TimeInterval = 10
) -> (output: String, exitCode: Int32?, session: PTYSession)? {
    let session: PTYSession
    do {
        session = try PTYSession(
            id: 1,
            command: command,
            environment: ["TERM": "xterm-256color", "PATH": "/usr/bin:/bin"],
            columns: columns,
            rows: rows,
            credentials: credentials,
            workingDirectory: workingDirectory,
            queue: harnessQueue
        )
    } catch {
        return nil
    }

    let lock = NSLock()
    var collected = Data()
    var exitCode: Int32?
    let finished = DispatchSemaphore(value: 0)

    session.start(
        onOutput: { _, data in
            lock.lock()
            collected.append(data)
            lock.unlock()
        },
        onExit: { _, code in
            lock.lock()
            exitCode = code
            lock.unlock()
            finished.signal()
        }
    )

    if let resizeTo {
        // Let the child settle so it observes the change rather than racing
        // its own startup.
        Thread.sleep(forTimeInterval: 0.3)
        session.resize(columns: resizeTo.columns, rows: resizeTo.rows)
    }
    if let input {
        Thread.sleep(forTimeInterval: 0.3)
        session.write(Data(input.utf8))
    }

    _ = finished.wait(timeout: .now() + timeout)
    lock.lock()
    let output = String(decoding: collected, as: UTF8.self)
    let code = exitCode
    lock.unlock()
    return (output, code, session)
}

func shellPath() -> String {
    for candidate in ["/bin/zsh", "/bin/bash", "/bin/sh"] where access(candidate, X_OK) == 0 {
        return candidate
    }
    return "/bin/sh"
}

print("PTY harness")

print("spawn and capture output")
if let result = run(command: ["/bin/echo", "hello-from-ighostty"]) {
    check(result.output.contains("hello-from-ighostty"), "child stdout reaches the host")
    check(result.exitCode == 0, "clean exit reports 0 (got \(String(describing: result.exitCode)))")
} else {
    check(false, "spawning /bin/echo succeeded")
}

// A terminal opens in the user's home, not wherever launchd started the
// daemon; a home that is not there is not used.
print("working directory")
if let result = run(command: ["/bin/sh", "-c", "pwd"], workingDirectory: "/private/tmp") {
    check(result.output.contains("/private/tmp"), "the child starts in the working directory")
} else {
    check(false, "spawning a shell with a working directory succeeded")
}
if let plan = ShellLaunch.plan(requestedShell: nil) {
    check(
        plan.workingDirectory == NSHomeDirectory(),
        "the default plan starts a session in the session user's home (got \(String(describing: plan.workingDirectory)))"
    )
}
let homelessUser = PasswdEntry(name: "nobody", uid: 0, gid: 0, home: "/nonexistent/ighostty-harness", shell: "/bin/sh")
check(ShellLaunch.workingDirectory(for: homelessUser) == nil, "a home that does not exist is skipped")

print("exit status decoding")
if let result = run(command: ["/bin/sh", "-c", "exit 7"]) {
    check(result.exitCode == 7, "non-zero exit is decoded (got \(String(describing: result.exitCode)))")
} else {
    check(false, "spawning /bin/sh succeeded")
}

print("signal death")
if let result = run(command: ["/bin/sh", "-c", "kill -TERM $$"]) {
    check(
        result.exitCode == 128 + 15,
        "a signalled child reports 128+signal (got \(String(describing: result.exitCode)))"
    )
} else {
    check(false, "spawning a self-terminating shell succeeded")
}

print("input reaches the child")
if let result = run(command: ["/bin/sh", "-c", "read line; echo GOT:$line"], input: "ping\n") {
    check(result.output.contains("GOT:ping"), "bytes written to the PTY are read by the child")
} else {
    check(false, "spawning a reading shell succeeded")
}

print("window size")
if let result = run(
    command: [shellPath(), "-c", "sleep 0.6; stty size"],
    columns: 80,
    rows: 24,
    resizeTo: (columns: 100, rows: 40)
) {
    // `stty size` prints "rows cols".
    check(
        result.output.contains("40 100"),
        "TIOCSWINSZ reaches the child (stty size said: \(result.output.split(separator: "\n").last.map(String.init) ?? "nothing"))"
    )
} else {
    check(false, "spawning a shell for stty succeeded")
}

print("initial window size")
if let result = run(command: [shellPath(), "-c", "stty size"], columns: 132, rows: 43) {
    check(result.output.contains("43 132"), "the size passed to forkpty is the child's initial size")
} else {
    check(false, "spawning a shell for the initial stty succeeded")
}

print("replay buffer")
if let result = run(command: ["/bin/echo", "replay-me"]) {
    let replay = String(decoding: result.session.replayData(), as: UTF8.self)
    check(replay.contains("replay-me"), "output is retained for reattaching clients")
    result.session.invalidate()
}

// The replay buffer is the daemon's only per-session accumulation, so it is
// the one thing that could grow without bound while a session runs.
print("replay buffer is capped")
let flood = iGhosttyProtocol.sessionReplayByteCount * 3
if let result = run(
    command: ["/bin/sh", "-c", "dd if=/dev/zero bs=1024 count=\(flood / 1024) 2>/dev/null | tr '\\0' 'x'"],
    timeout: 30
) {
    let retained = result.session.replayData().count
    check(
        retained <= iGhosttyProtocol.sessionReplayByteCount,
        "a session that printed \(flood / 1024) KiB retains at most \(iGhosttyProtocol.sessionReplayByteCount / 1024) KiB (kept \(retained / 1024) KiB)"
    )
    check(
        retained > iGhosttyProtocol.sessionReplayByteCount / 2,
        "and it keeps the most recent output rather than discarding everything"
    )
    result.session.invalidate()
    check(
        result.session.replayData().isEmpty,
        "invalidating a session releases the buffer instead of waiting for deinit"
    )
} else {
    check(false, "spawning a shell that floods the buffer succeeded")
}

// A shell inherits every descriptor that survives execve. With another
// session alive — its PTY master, the spawn pipe, the dispatch sources'
// kqueue — a new shell must still see nothing beyond its own terminal:
// anything else is a leaked handle on another session, and a hole in the
// per-process fd budget tools like codex burn through.
print("descriptors do not leak into the child")
do {
    let bystander = try PTYSession(
        id: 4,
        command: ["/bin/sh", "-c", "sleep 5"],
        environment: ["PATH": "/usr/bin:/bin"],
        columns: 80,
        rows: 24,
        queue: harnessQueue
    )
    bystander.start(onOutput: { _, _ in }, onExit: { _, _ in })
    Thread.sleep(forTimeInterval: 0.2)
    // The shell lists its own table: `ls /dev/fd` would add the descriptors
    // `ls` opens for the listing itself. The trailing `:` keeps sh from
    // exec-ing lsof in place, which would make `$$` lsof and list its pipes.
    if let result = run(command: ["/bin/sh", "-c", "/usr/sbin/lsof -p $$ -a -d 0-1024; :"], timeout: 20) {
        // The PTY turns every newline into "\r\n", one Character in Swift.
        let lines = result.output.split(whereSeparator: \.isNewline).map(String.init)
        // lsof rows: COMMAND PID USER FD TYPE ...; FD is "0u", "3r", "cwd"...
        let descriptors = lines.dropFirst().compactMap { line -> Int? in
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count > 3 else { return nil }
            return Int(columns[3].prefix { $0.isNumber })
        }
        check(
            descriptors.sorted() == [0, 1, 2],
            "a child holds nothing beyond its terminal (saw \(descriptors.sorted()))"
        )
        result.session.invalidate()
    } else {
        check(false, "spawning a shell to list its descriptors succeeded")
    }
    bystander.invalidate()
} catch {
    check(false, "spawning the bystander session succeeded")
}

// The NOTE_EXIT race (see PTYSession.start): a background child keeping the
// tty open is the case that exposed it — the exit must still arrive
// promptly, not when the straggler finally lets go.
print("exit is reported while a background child holds the terminal")
let holdStart = Date()
if let result = run(command: ["/bin/sh", "-c", "sleep 4 & exit 5"], timeout: 6) {
    let elapsed = Date().timeIntervalSince(holdStart)
    check(result.exitCode == 5, "the shell's own status is reported (got \(String(describing: result.exitCode)))")
    check(elapsed < 2, "and it arrives before the straggler exits (took \(String(format: "%.2f", elapsed))s)")
    result.session.invalidate()
} else {
    check(false, "spawning a shell with a background child succeeded")
}

print("rejecting a bad command")
do {
    _ = try PTYSession(
        id: 2,
        command: [],
        environment: [:],
        columns: 80,
        rows: 24,
        queue: harnessQueue
    )
    check(false, "an empty command is rejected")
} catch {
    check(true, "an empty command is rejected")
}

// A child that never reaches execve reports why through the spawn pipe, so
// the app can show the real reason instead of "no usable shell was found".
print("spawn failures explain themselves")
for (command, expected) in [
    (["/bin/nope-not-here"], "No such file"),
    (["/etc"], "Permission denied"),
] {
    do {
        _ = try PTYSession(
            id: 3,
            command: command,
            environment: [:],
            columns: 80,
            rows: 24,
            queue: harnessQueue
        )
        check(false, "spawning \(command[0]) fails")
    } catch let failure as iGhosttyFailure {
        check(
            failure.code == .spawnFailed
                && failure.message.contains(command[0])
                && failure.message.contains(expected),
            "\(command[0]) reports the real errno (said: \(failure.message))"
        )
    } catch {
        check(false, "spawning \(command[0]) throws iGhosttyFailure, not \(error)")
    }
}

print("jailbreak path resolution")
// The harness does not run from /usr/libexec/ighosttyd, so no bootstrap is
// found and every mapping degrades to identity — the same stub behaviour
// roothide's own API has on a rootful system.
check(JailbreakRoot.bootstrap == .none, "no bootstrap is detected off-device")
check(JailbreakRoot.path == nil, "so there is no install prefix")
check(
    JailbreakRoot.resolve("/bin/sh") == "/bin/sh",
    "resolution is identity without a bootstrap"
)
check(
    JailbreakRoot.bootstrapPath("/bin/sh") == "/bin/sh",
    "and so is the bootstrap's own spelling"
)
check(
    JailbreakRoot.systemPath("/bin/sh") == "/bin/sh",
    "and so is the system's"
)

// Only one layout is ever live on a given device, so exercise each one's three
// vocabularies directly. Mixing them up is the bug this type exists to prevent.
let jbroot = "/var/containers/Bundle/Application/.jbroot-0123456789ABCDEF"
let roothide = JailbreakRoot.Bootstrap.roothide(jbroot: jbroot)
check(
    roothide.bootstrapPath("/bin/zsh") == "/bin/zsh",
    "roothide leaves the bootstrap's own paths unprefixed — vroot resolves them"
)
check(
    roothide.resolve("/bin/zsh") == "\(jbroot)/bin/zsh",
    "but the kernel is handed the jbroot-prefixed path"
)
check(
    roothide.systemPath("/usr/bin") == "/rootfs/usr/bin",
    "and iOS's own filesystem is reached through the jbroot's /rootfs bridge"
)

let rootless = JailbreakRoot.Bootstrap.rootless(prefix: "/var/jb")
check(
    rootless.bootstrapPath("/bin/zsh") == "/var/jb/bin/zsh",
    "rootless prefixes the bootstrap's own paths — its binaries have /var/jb compiled in"
)
check(
    rootless.resolve("/var/jb/bin/zsh") == "/var/jb/bin/zsh",
    "so they are already what the kernel wants"
)
check(
    rootless.systemPath("/usr/bin") == "/usr/bin",
    "and iOS's own filesystem is just itself"
)
check(JailbreakRoot.isExecutable("/bin/sh"), "an existing shell is seen as executable")
check(!JailbreakRoot.isExecutable("/bin/nope-not-here"), "a missing shell is not")
check(!JailbreakRoot.isExecutable("/etc"), "a directory is not executable")

print("shell launch planning")
if let plan = ShellLaunch.plan(requestedShell: nil) {
    check(plan.command.first?.hasPrefix("/") == true, "the default plan execs an absolute path")
    check(plan.environment["TERM"] == "xterm-256color", "TERM is set")
    check(plan.environment["TERM_PROGRAM"] == "iGhostty", "TERM_PROGRAM identifies the app")
    // Naming a locale the system cannot load is worse than naming none:
    // setlocale fails and everything silently falls back to C, which is where
    // multibyte input starts drawing one byte at a time.
    let ctype = plan.environment["LC_CTYPE"] ?? ""
    check(ctype.hasSuffix("UTF-8"), "LC_CTYPE selects a UTF-8 locale (got '\(ctype)')")
    check(
        FileManager.default.fileExists(atPath: "/usr/share/locale/\(ctype)/LC_CTYPE"),
        "the exported LC_CTYPE names a locale this system can actually load"
    )
    // LANG and LC_ALL set every category at once; on iOS only LC_CTYPE has
    // data, so either of them fails and takes the whole process back to C.
    check(plan.environment["LANG"] == nil, "LANG is left alone — it would set every category")
    check(plan.environment["LC_ALL"] == nil, "LC_ALL is left alone for the same reason")
    // Sessions are always spawned directly — `login` is off the table because
    // Procursus's pam_launchd.so moves the session into a bootstrap namespace
    // that cannot reach mDNSResponder, killing DNS (see ShellLaunch.plan).
    check(
        plan.command.first?.hasSuffix("/login") != true,
        "the default plan never routes through login — pam_launchd would cost the session its DNS"
    )
    check(plan.environment["PATH"] != nil, "a directly spawned shell is given a PATH")
    check(plan.environment["USER"] != nil, "a directly spawned shell is told who it is")
    check(plan.environment["HOME"] != nil, "a directly spawned shell is given a HOME")
} else {
    check(false, "a default plan is produced")
}

print("shell integration")
// Nothing is injected when the scripts are not installed — the harness host
// has no /usr/share/ighostty, which is also the state of a device where the
// package predates them. A stray `--posix` here would start every bash
// session in a mode its rc files are not written for.
var integrationEnvironment: [String: String] = ["HOME": "/tmp"]
check(
    ShellIntegration.apply(
        shell: "/bin/bash",
        to: &integrationEnvironment,
        canModifyArguments: true
    ).isEmpty,
    "no scripts on disk means no arguments are added"
)
check(
    integrationEnvironment == ["HOME": "/tmp"],
    "no scripts on disk means the environment is left alone"
)
// `sh` is not a shell anyone ships an integration for, and pointing it at
// another shell's rc files is how a session ends up printing syntax errors
// before its first prompt.
var shEnvironment: [String: String] = [:]
check(
    ShellIntegration.apply(
        shell: "/bin/sh",
        to: &shEnvironment,
        canModifyArguments: true
    ).isEmpty && shEnvironment.isEmpty,
    "sh is left untouched"
)

if let plan = ShellLaunch.plan(requestedShell: "/bin/sh") {
    check(plan.command == ["/bin/sh", "-il"], "an explicit shell is spawned as a login shell")
    let directories = (plan.environment["PATH"] ?? "").split(separator: ":").map(String.init)
    check(directories.contains("/usr/bin"), "PATH reaches the system's own tools")
    check(
        directories.allSatisfy { !$0.hasPrefix("/var/jb") && !$0.hasPrefix("/rootfs") },
        "with no bootstrap, PATH assumes no jailbreak layout"
    )
    check(
        Set(directories).count == directories.count,
        "the bootstrap and system halves collapse into one another without duplicates"
    )
} else {
    check(false, "an explicit shell produces a plan")
}

check(ShellLaunch.plan(requestedShell: "/bin/nope-not-here") == nil, "a missing shell is rejected")
check(ShellLaunch.plan(requestedShell: "bin/sh") == nil, "a relative shell path is rejected")
check(ShellLaunch.validate(["/bin/echo", "hi"]) != nil, "an absolute argv is accepted")
check(ShellLaunch.validate(["echo", "hi"]) == nil, "a relative argv is rejected")
check(
    ShellLaunch.validate(["/bin/echo"] + Array(repeating: "x", count: 200)) == nil,
    "an over-long argv is rejected"
)

print("passwd lookup")
if let entry = PasswdEntry.forCurrentUser() {
    check(entry.uid == getuid(), "the current user is found")
    check(entry.shell.hasPrefix("/"), "the passwd shell is an absolute path")
} else {
    check(false, "the current user is found")
}
// By name, from the passwd *file* — the daemon looks `mobile` up this way
// because libc answers from the system database, which on the device is the
// iOS one and has no bootstrap users in it. `root` is the one name present in
// the file on both the device and the host.
if let root = PasswdEntry.forUser(name: "root") {
    check(root.uid == 0 && root.gid == 0, "a user is findable by name in the passwd file")
    check(root.shell.hasPrefix("/"), "the named user's shell is an absolute path")
} else {
    check(false, "a user is findable by name in the passwd file")
}

print("privilege drop")
// The daemon runs as root and its sessions must not: only root can change
// uid, so an unprivileged harness asserts the planner refuses to try, and a
// root one asserts the child really lands on the target user.
if getuid() == 0 {
    // `mobile` on the device; on the host, any unprivileged user the passwd
    // file actually lists (macOS keeps normal users in DirectoryService, and
    // `nobody`'s negative uid does not survive parsing as a uid_t).
    let target = PasswdEntry.forUser(name: "mobile")
        ?? PasswdEntry.forUser(name: "daemon")
    if let target {
        let credentials = ShellLaunch.Credentials(uid: target.uid, gid: target.gid)
        check(
            ShellLaunch.credentials(for: target) == credentials,
            "root drops to the session user"
        )
        if let result = run(command: ["/usr/bin/id", "-u"], credentials: credentials) {
            check(
                result.output.contains("\(target.uid)"),
                "the child execs as uid \(target.uid) (id said: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines)))"
            )
            result.session.invalidate()
        } else {
            check(false, "a privilege-dropping session spawns")
        }
    }
} else {
    check(
        ShellLaunch.credentials(for: PasswdEntry.forCurrentUser()) == nil,
        "a non-root daemon drops nothing — setuid would only fail"
    )
}

if failures.isEmpty {
    print("\nPTY harness passed")
    exit(EXIT_SUCCESS)
} else {
    print("\nPTY harness failed: \(failures.count) check(s)")
    for failure in failures {
        print("  - \(failure)")
    }
    exit(EXIT_FAILURE)
}
