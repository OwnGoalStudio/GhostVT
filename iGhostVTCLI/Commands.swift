import Darwin
import Foundation
import XPC

/// What each subcommand does. Every one of them opens a connection, says
/// hello, asks its question, and goes away — the CLI attaches to nothing,
/// so a session the app is showing keeps its tab while this runs.
enum Commands {
    static func list() throws -> Int32 {
        let client = DaemonClient()
        try client.connect()
        defer { client.cancel() }
        let sessions = DaemonClient.sessions(in: try client.request(.listSessions))
        guard !sessions.isEmpty else { return 0 }

        var table: [[String]] = [["SID", "PROC", "SIZE", "ATT", "CWD"]]
        for session in sessions {
            table.append([
                String(session.id),
                session.processName ?? session.title,
                "\(session.columns)x\(session.rows)",
                session.isAttached ? "yes" : "no",
                session.currentDirectory ?? "-",
            ])
        }
        let widths = (0 ..< 5).map { column in table.map { $0[column].count }.max() ?? 0 }
        for row in table {
            var line = ""
            for (column, field) in row.enumerated() {
                line += column == row.count - 1
                    ? field
                    : field.padding(toLength: widths[column] + 2, withPad: " ", startingAt: 0)
            }
            print(line.trimmedTrailingSpaces())
        }
        return 0
    }

    static func capture(sessionID: UInt64, full: Bool) throws -> Int32 {
        let client = DaemonClient()
        try client.connect()
        defer { client.cancel() }
        let reply = try client.request(.snapshotSession) {
            xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, sessionID)
        }
        let columns = UInt16(truncatingIfNeeded: xpc_dictionary_get_uint64(reply, iGhostVTWireKey.columns))
        let rows = UInt16(truncatingIfNeeded: xpc_dictionary_get_uint64(reply, iGhostVTWireKey.rows))
        let renderer = ScreenRenderer(
            columns: columns == 0 ? iGhostVTProtocol.defaultColumns : columns,
            rows: rows == 0 ? iGhostVTProtocol.defaultRows : rows
        )
        if let replay = DaemonClient.data(reply, iGhostVTWireKey.data) {
            renderer.feed(replay)
        }
        let text = full ? renderer.transcriptText() : renderer.screenText()
        if !text.isEmpty {
            print(text)
        }
        return 0
    }

    static func send(sessionID: UInt64, input: [UInt8]) throws -> Int32 {
        let client = DaemonClient()
        try client.connect()
        defer { client.cancel() }
        // One message per chunk, in order — the daemon buffers what the
        // program has not read yet. Nothing a user types on a command line
        // comes near one chunk; a `text` argument read from a file might.
        var offset = 0
        repeat {
            let end = min(input.count, offset + iGhostVTProtocol.inputChunkByteCount)
            let chunk = Array(input[offset ..< end])
            try client.request(.injectInput) { message in
                xpc_dictionary_set_uint64(message, iGhostVTWireKey.sessionID, sessionID)
                chunk.withUnsafeBytes {
                    xpc_dictionary_set_data(message, iGhostVTWireKey.data, $0.baseAddress!, $0.count)
                }
            }
            offset = end
        } while offset < input.count
        return 0
    }

    static func new(command: [String]) throws -> Int32 {
        let client = DaemonClient()
        try client.connect()
        defer { client.cancel() }
        let reply = try client.request(.openSession) { message in
            // A nominal grid: nothing here is going to display the session,
            // and whoever attaches sets the real size. The daemon starts the
            // shell in the session user's home — the CLI names no directory
            // and inherits none, because it is not a tab beside another one.
            xpc_dictionary_set_uint64(message, iGhostVTWireKey.columns, UInt64(iGhostVTProtocol.defaultColumns))
            xpc_dictionary_set_uint64(message, iGhostVTWireKey.rows, UInt64(iGhostVTProtocol.defaultRows))
            guard !command.isEmpty else { return }
            let arguments = xpc_array_create(nil, 0)
            for argument in command.prefix(iGhostVTProtocol.maximumCommandArgumentCount) {
                xpc_array_append_value(arguments, xpc_string_create(argument))
            }
            xpc_dictionary_set_value(message, iGhostVTWireKey.command, arguments)
        }
        print(xpc_dictionary_get_uint64(reply, iGhostVTWireKey.sessionID))
        return 0
    }

    static func kill(sessionID: UInt64) throws -> Int32 {
        let client = DaemonClient()
        try client.connect()
        defer { client.cancel() }
        try client.request(.closeSession) {
            xpc_dictionary_set_uint64($0, iGhostVTWireKey.sessionID, sessionID)
        }
        // The reply says the SIGHUP went out, not that the shell is gone —
        // it gets a grace period to run its exit hooks before the daemon
        // kills it. Wait for the session to actually leave the list, the
        // way the app does as it quits.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let sessions = DaemonClient.sessions(in: try client.request(.listSessions))
            if !sessions.contains(where: { $0.id == sessionID }) {
                return 0
            }
            usleep(100_000)
        }
        throw CLIError.sessionLingered(sessionID)
    }
}

private extension String {
    func trimmedTrailingSpaces() -> String {
        var text = self
        while text.hasSuffix(" ") { text.removeLast() }
        return text
    }
}
