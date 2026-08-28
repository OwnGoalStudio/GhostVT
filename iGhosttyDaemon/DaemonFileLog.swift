import Darwin
import Dispatch
import Foundation

/// On-disk mirror of the daemon's important events.
///
/// os_log from a jbroot daemon does not reliably reach `log`/idevicesyslog on
/// every bootstrap, and the daemon is exactly the process that needs a post-
/// mortem trail when the app can only say "connection lost". The file lives
/// in mobile's Logs so it is writable whether the daemon runs as root or as
/// mobile, and readable over ssh without elevation.
enum DaemonFileLog {
    #if os(macOS)
        // The Mac Catalyst harness runs the daemon as the user; mobile's
        // home does not exist there.
        private static let path = NSHomeDirectory() + "/Library/Logs/ighosttyd.log"
    #else
        private static let path = "/var/mobile/Library/Logs/ighosttyd.log"
    #endif
    private static let rotatedPath = path + ".1"
    private static let rotateAtBytes = 512 * 1024
    private static let queue = DispatchQueue(
        label: "wiki.qaq.ighostty.daemon.filelog",
        qos: .utility
    )

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// mobile's Library/Logs does not exist until someone makes it.
    private static let directoryReady: Bool = {
        (try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )) != nil
    }()

    static func log(_ message: String) {
        let line = "\(formatter.string(from: Date())) [\(getpid())] \(message)\n"
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

    private static func rotateIfNeeded() {
        var info = stat()
        guard stat(path, &info) == 0, info.st_size > rotateAtBytes else { return }
        _ = unlink(rotatedPath)
        _ = rename(path, rotatedPath)
    }
}
