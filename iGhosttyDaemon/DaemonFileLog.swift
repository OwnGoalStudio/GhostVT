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
    private static let path = "/var/mobile/Library/Logs/ighosttyd.log"
    private static let rotatedPath = "/var/mobile/Library/Logs/ighosttyd.log.1"
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

    /// The daemon is vroot-linked on roothide, so this resolves inside the
    /// jbroot — where Library/Logs does not exist until someone makes it.
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
            guard let data = line.data(using: .utf8) else { return }
            if let handle = FileHandle(forWritingAtPath: path) {
                // The log is written off the control queue, so a forkpty on
                // that queue can land while this handle is open. Every
                // descriptor the daemon holds at fork time reaches the
                // shell unless it is close-on-exec — and a root-owned log
                // is not something a mobile shell should hold open.
                _ = fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC)
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                // First line ever, or the file was deleted out from under us.
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    private static func rotateIfNeeded() {
        var info = stat()
        guard stat(path, &info) == 0, info.st_size > rotateAtBytes else { return }
        _ = unlink(rotatedPath)
        _ = rename(path, rotatedPath)
    }
}
