//
//  TerminalDebugFileLog.swift
//  iGhostVT
//

import Foundation

/// A file copy of the terminal debug log for the device, where the unified
/// log's relay drops lines under load (a post-boot launch loses most of
/// them). `Documents/ighostvt-debug.log`, truncated on every `open()`, one
/// line per message with a wall-clock stamp; `write` is a no-op until
/// `open()` ran, so the session store's stamps cost nothing when the
/// verbose log is off. Pull it with `scp` over usbmuxd or read it from the
/// app's container.
enum TerminalDebugFileLog {
    private static let queue = DispatchQueue(label: "wiki.qaq.iGhostVT.debug-log")
    private nonisolated(unsafe) static var handle: FileHandle?
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func open() {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ighostvt-debug.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
    }

    static func write(_ message: String) {
        let line = "\(stamp.string(from: Date())) \(message)\n"
        queue.async {
            handle?.write(Data(line.utf8))
        }
    }
}
