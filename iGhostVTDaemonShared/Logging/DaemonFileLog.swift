import Darwin
import Dispatch

/// On-disk mirror of the daemon's important events.
///
/// os_log from a jbroot daemon does not reliably reach `log`/idevicesyslog on
/// every bootstrap, and the daemon is exactly the process that needs a post-
/// mortem trail when the app can only say "connection lost". The file lives
/// in mobile's Logs so it is writable whether the daemon runs as root or as
/// mobile, and readable over ssh without elevation.
///
/// Both `ighostvtd` and `ighostvtd-io` write here; each line names its
/// process. No Foundation on purpose: the proxy lives under a 6 MB jetsam
/// limit and a `DateFormatter` alone drags ICU in.
///
/// The location is the protocol's (`iGhostVTProtocol.daemonLogPath`): the
/// app's log viewer reads this file, so the two must agree on where it is.
/// The line format is likewise read back by the app — keep
/// `LogReader.parseDaemonLine` in step with `log(_:)`.
enum DaemonFileLog {
    private static let path = iGhostVTProtocol.daemonLogPath
    private static let rotatedPath = iGhostVTProtocol.rotatedDaemonLogPath
    private static let rotateAtBytes = 512 * 1024
    private static let queue = DispatchQueue(
        label: "wiki.qaq.ighostvt.daemon.filelog",
        qos: .utility
    )
    private static let processName = String(cString: getprogname())

    /// mobile's Library/Logs does not exist until someone makes it.
    private static let directoryReady: Bool = makeDirectory(directory(of: path))

    static func log(_ message: String) {
        let line = "\(timestamp()) [\(getpid()) \(processName)] \(message)\n"
        queue.async {
            _ = directoryReady
            rotateIfNeeded()
            // Off the control queue, so a forkpty can land while this is
            // open: close-on-exec from the start (AGENTS.md, descriptors).
            let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
            guard descriptor >= 0 else { return }
            defer { close(descriptor) }
            let bytes = Array(line.utf8)
            _ = bytes.withUnsafeBytes { writeFully(descriptor, $0) }
        }
    }

    private static func timestamp() -> String {
        var now = timeval()
        gettimeofday(&now, nil)
        var seconds = now.tv_sec
        var parts = tm()
        localtime_r(&seconds, &parts)
        var buffer = [CChar](repeating: 0, count: 32)
        let length = strftime(&buffer, buffer.count, "%m-%d %H:%M:%S", &parts)
        guard length > 0 else { return "?" }
        let millis = Int(now.tv_usec) / 1000
        let padding = millis < 10 ? "00" : millis < 100 ? "0" : ""
        return String(cString: buffer) + "." + padding + String(millis)
    }

    private static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "." }
        return String(path[..<slash])
    }

    /// `mkdir -p`: every missing component, existing ones left alone.
    private static func makeDirectory(_ path: String) -> Bool {
        var current = ""
        for component in path.split(separator: "/") {
            current += "/" + component
            if mkdir(current, 0o755) != 0, errno != EEXIST {
                return false
            }
        }
        return true
    }

    private static func rotateIfNeeded() {
        var info = stat()
        guard stat(path, &info) == 0, info.st_size > rotateAtBytes else { return }
        _ = unlink(rotatedPath)
        _ = rename(path, rotatedPath)
    }
}
