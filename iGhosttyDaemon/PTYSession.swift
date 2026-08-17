import Darwin
import Dispatch
import Foundation

/// One pseudo-terminal and the process running on it.
///
/// This is the only place in the product that creates a process. The app has
/// no path to `fork`/`exec` at all: it can ask the daemon to open a session
/// and the daemon decides what runs.
final class PTYSession {
    typealias OutputHandler = (UInt64, Data) -> Void
    typealias ExitHandler = (UInt64, Int32) -> Void

    let id: UInt64
    let command: [String]
    private(set) var columns: UInt16
    private(set) var rows: UInt16
    private(set) var isAlive = true

    /// Recent output, replayed when a client attaches. The daemon holds this
    /// so a relaunched app can rebuild the screen without the shell knowing
    /// anything happened.
    private var replayBuffer = Data()

    private let queue: DispatchQueue
    private let master: Int32
    private let childPID: pid_t
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?

    private var onOutput: OutputHandler?
    private var onExit: ExitHandler?

    /// Where the child gave up, reported through the spawn pipe. Plain
    /// constants rather than an enum: the child may only make
    /// async-signal-safe calls, and these are read straight into raw memory.
    private static let stepChownTTY: Int32 = 1
    private static let stepSetGroups: Int32 = 2
    private static let stepSetGID: Int32 = 3
    private static let stepSetUID: Int32 = 4
    private static let stepVerifyUID: Int32 = 5
    private static let stepExec: Int32 = 6

    private static func systemMessage(_ code: Int32) -> String {
        String(cString: strerror(code))
    }

    /// True when the child reported a failure; false on EOF, which is what a
    /// successful `execve` looks like from here.
    private static func readReport(
        from descriptor: Int32,
        into buffer: UnsafeMutablePointer<Int32>
    ) -> Bool {
        let wanted = MemoryLayout<Int32>.size * 2
        var total = 0
        while total < wanted {
            let count = read(
                descriptor,
                UnsafeMutableRawPointer(buffer).advanced(by: total),
                wanted - total
            )
            if count > 0 {
                total += count
                continue
            }
            if count < 0, errno == EINTR { continue }
            break
        }
        return total == wanted
    }

    private static func describeChildFailure(
        step: Int32,
        code: Int32,
        executable: String,
        credentials: ShellLaunch.Credentials?
    ) -> String {
        let user = credentials.map { "uid \($0.uid)" } ?? "the session user"
        switch step {
        case stepExec:
            return "could not run \(executable): \(systemMessage(code))"
        case stepChownTTY:
            return "could not hand the terminal to \(user): \(systemMessage(code))"
        case stepVerifyUID:
            return "the session refused to start because it was still root after dropping to \(user)"
        default:
            return "could not drop privileges to \(user): \(systemMessage(code))"
        }
    }

    /// Prepared before `forkpty` so the child only has to call `execve`:
    /// anything else between fork and exec is unsafe in a Swift process.
    private static func makeCStringArray(_ values: [String]) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
        let array = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(
            capacity: values.count + 1
        )
        for (index, value) in values.enumerated() {
            array[index] = strdup(value)
        }
        array[values.count] = nil
        return array
    }

    private static func freeCStringArray(
        _ array: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
        count: Int
    ) {
        for index in 0 ..< count {
            free(array[index])
        }
        array.deallocate()
    }

    init(
        id: UInt64,
        command: [String],
        environment: [String: String],
        columns: UInt16,
        rows: UInt16,
        credentials: ShellLaunch.Credentials? = nil,
        queue: DispatchQueue
    ) throws {
        guard let executable = command.first, !executable.isEmpty else {
            throw iGhosttyFailure(.spawnFailed, "the session had no command to run")
        }

        self.id = id
        self.command = command
        self.columns = columns
        self.rows = rows
        self.queue = queue

        let environmentStrings = environment.map { "\($0.key)=\($0.value)" }.sorted()
        let argv = Self.makeCStringArray(command)
        let envp = Self.makeCStringArray(environmentStrings)
        let executablePath = strdup(executable)
        defer {
            Self.freeCStringArray(argv, count: command.count)
            Self.freeCStringArray(envp, count: environmentStrings.count)
            free(executablePath)
        }

        var size = winsize(
            ws_row: rows,
            ws_col: columns,
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        // Prepared before the fork for the same reason the argv is: the child
        // may only make async-signal-safe calls, and building an array is not
        // one of them.
        var supplementaryGroups: [gid_t] = credentials.map { [$0.gid] } ?? []

        // How the child says why it never reached `execve`. The write end is
        // close-on-exec, so a successful exec closes it and the parent simply
        // reads EOF; any other outcome arrives as (step, errno). Without this
        // the only evidence is an exit status of 126 or 127, which cannot say
        // whether the shell was missing, unreadable, or refused.
        var reportDescriptors: [Int32] = [-1, -1]
        guard pipe(&reportDescriptors) == 0 else {
            throw iGhosttyFailure(
                .spawnFailed,
                "could not create the spawn report pipe: \(Self.systemMessage(errno))"
            )
        }
        let reportRead = reportDescriptors[0]
        let reportWrite = reportDescriptors[1]
        _ = fcntl(reportWrite, F_SETFD, FD_CLOEXEC)
        // Allocated before the fork like everything else the child touches.
        let report = UnsafeMutablePointer<Int32>.allocate(capacity: 2)
        defer { report.deallocate() }

        var masterDescriptor: Int32 = -1
        let pid = ighosttyForkPTY(&masterDescriptor, nil, nil, &size)
        if pid == 0 {
            // Child: everything below is a bare syscall, and everything it
            // needs was allocated above. `_exit` avoids running the parent's
            // atexit handlers if exec fails.
            close(reportRead)
            func fail(_ step: Int32) -> Never {
                report[0] = step
                report[1] = errno
                _ = Darwin.write(reportWrite, report, MemoryLayout<Int32>.size * 2)
                _exit(step == Self.stepExec ? 127 : 126)
            }
            if let credentials {
                // The daemon is root and the session must not be. Order
                // matters: once the uid is gone the group changes are no
                // longer permitted. A failure here has to be fatal — execing
                // anyway would hand the user the root shell we just refused.
                if fchown(STDIN_FILENO, credentials.uid, credentials.gid) != 0 { fail(Self.stepChownTTY) }
                _ = fchmod(STDIN_FILENO, 0o620)
                if setgroups(1, &supplementaryGroups) != 0 { fail(Self.stepSetGroups) }
                if setgid(credentials.gid) != 0 { fail(Self.stepSetGID) }
                if setuid(credentials.uid) != 0 { fail(Self.stepSetUID) }
                // Belt and braces: if the uid did not actually change, refuse.
                if getuid() != credentials.uid || geteuid() != credentials.uid { fail(Self.stepVerifyUID) }
            }
            execve(executablePath, argv, envp)
            fail(Self.stepExec)
        }
        close(reportWrite)
        guard pid > 0, masterDescriptor >= 0 else {
            close(reportRead)
            throw iGhosttyFailure(.spawnFailed, "forkpty failed: \(Self.systemMessage(errno))")
        }
        // Blocks only until the child execs (EOF) or gives up (8 bytes).
        let reported = Self.readReport(from: reportRead, into: report)
        close(reportRead)
        if reported {
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)
            close(masterDescriptor)
            throw iGhosttyFailure(
                .spawnFailed,
                Self.describeChildFailure(
                    step: report[0],
                    code: report[1],
                    executable: executable,
                    credentials: credentials
                )
            )
        }

        master = masterDescriptor
        childPID = pid
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL, 0) | O_NONBLOCK)
    }

    func start(onOutput: @escaping OutputHandler, onExit: @escaping ExitHandler) {
        self.onOutput = onOutput
        self.onExit = onExit

        let readSource = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        readSource.setEventHandler { [weak self] in
            self?.drainAvailableOutput()
        }
        self.readSource = readSource
        readSource.activate()

        let exitSource = DispatchSource.makeProcessSource(
            identifier: childPID,
            eventMask: .exit,
            queue: queue
        )
        exitSource.setEventHandler { [weak self] in
            self?.reapChild()
        }
        self.exitSource = exitSource
        exitSource.activate()

        // A process source registered after its process already died never
        // fires, and a fast child (/bin/echo) can beat the registration. One
        // poll on the queue closes that window — reapChild's WNOHANG makes it
        // a no-op while the child is still running.
        queue.async { [weak self] in
            self?.reapChild()
        }
    }

    /// Bytes typed by the user, forwarded to the shell.
    func write(_ data: Data) {
        guard isAlive, !data.isEmpty else { return }
        data.withUnsafeBytes { buffer in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(master, pointer, remaining)
                if written > 0 {
                    pointer += written
                    remaining -= written
                    continue
                }
                if written < 0, errno == EINTR { continue }
                // EAGAIN on a full PTY buffer: the shell is not draining, so
                // dropping the tail beats blocking the daemon's queue.
                break
            }
        }
    }

    func resize(columns: UInt16, rows: UInt16) {
        guard isAlive else { return }
        self.columns = columns
        self.rows = rows
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)
    }

    /// Everything the daemon has buffered for this session, oldest first.
    func replayData() -> Data {
        replayBuffer
    }

    func terminate() {
        guard isAlive else { return }
        kill(childPID, SIGHUP)
    }

    func invalidate() {
        readSource?.cancel()
        readSource = nil
        exitSource?.cancel()
        exitSource = nil
        onOutput = nil
        onExit = nil
        // Released here rather than left to deinit: this is what the daemon
        // is holding per session, and a caller may keep the object alive a
        // little longer than the session it stands for.
        replayBuffer = Data()
        if isAlive {
            kill(childPID, SIGKILL)
            isAlive = false
            // Reaped so the child does not linger as a zombie: the process
            // source is already cancelled, so nothing else ever will, and
            // leaked process-table entries are their own kind of growth.
            //
            // Never with a blocking wait, though. This runs on the daemon's
            // one control queue, and a blocking `waitpid` here once froze
            // the entire daemon — listener and all — when the grace-kill
            // path met a child the kernel was slow to end. WNOHANG polling
            // keeps the queue alive no matter what the child does.
            Self.reapWithoutBlocking(childPID, on: queue)
        }
        close(master)
    }

    /// WNOHANG-polls the killed child off the queue instead of blocking on
    /// it. Gives up after ~5s; a zombie then is the kernel's problem, not a
    /// deaf daemon.
    private static func reapWithoutBlocking(
        _ pid: pid_t,
        on queue: DispatchQueue,
        attempt: Int = 0
    ) {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid || (result < 0 && errno != EINTR) {
            return
        }
        guard attempt < 25 else {
            DaemonFileLog.log("child \(pid) not reapable after SIGKILL, leaving it")
            return
        }
        queue.asyncAfter(deadline: .now() + 0.2) {
            reapWithoutBlocking(pid, on: queue, attempt: attempt + 1)
        }
    }

    // MARK: - Internals

    private func drainAvailableOutput() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { destination -> Int in
                guard let base = destination.baseAddress else { return -1 }
                return read(master, base, destination.count)
            }
            if count > 0 {
                let data = Data(buffer[0 ..< count])
                append(data)
                onOutput?(id, data)
                continue
            }
            if count < 0, errno == EINTR { continue }
            if count == 0 {
                // EOF: the child closed the terminal. The process source
                // reports the status.
                readSource?.cancel()
                readSource = nil
            }
            return
        }
    }

    private func append(_ data: Data) {
        replayBuffer.append(data)
        let excess = replayBuffer.count - iGhosttyProtocol.sessionReplayByteCount
        if excess > 0 {
            replayBuffer.removeFirst(excess)
        }
    }

    private func reapChild() {
        guard isAlive else { return }
        var status: Int32 = 0
        let result = waitpid(childPID, &status, WNOHANG)
        guard result == childPID || result < 0 else { return }
        isAlive = false

        let exitCode: Int32 = if result < 0 {
            -1
        } else if status & 0x7F == 0 {
            (status >> 8) & 0xFF
        } else {
            128 + (status & 0x7F)
        }

        // Let any output written just before exit reach the client first.
        drainAvailableOutput()
        onExit?(id, exitCode)
    }

    deinit {
        readSource?.cancel()
        exitSource?.cancel()
    }
}

enum iGhosttyDaemonError: Error {
    case transportFailure
}
