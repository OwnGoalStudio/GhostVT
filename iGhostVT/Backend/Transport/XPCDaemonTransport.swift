import Darwin
import Dispatch
import Foundation
import iGhostVTKit
@preconcurrency import XPC

@_silgen_name("xpc_connection_create_mach_service")
private func ighostvtCreateMachServiceConnection(
    _ name: UnsafePointer<CChar>,
    _ queue: DispatchQueue?,
    _ flags: UInt64
) -> xpc_connection_t?

/// Terminal I/O carried by `ighostvtd`.
///
/// The app cannot spawn anything: it asks the daemon to open a session and
/// then only pushes keystrokes and grid sizes. Because the daemon owns the
/// session, `connect()` prefers reattaching to a session this transport
/// already had — relaunching the app restores the running shell, replayed
/// output and all, rather than starting a fresh one.
public final class XPCDaemonTransport: TerminalTransport, @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "wiki.qaq.ighostvt.client.xpc",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem
    )
    private let lock = NSLock()
    private var connection: xpc_connection_t?
    private var sessionID: UInt64?
    /// The grid the host reported most recently, so an open spawns the shell
    /// at the size the surface has rather than the protocol default. Confined
    /// to `queue`, as is every size decision below: `updateViewport` hops
    /// there, and the open/attach replies arrive there.
    private var latestViewport: (columns: Int, rows: Int)?
    /// The grid the daemon's session is known to hold — what the open spawned
    /// at, what the attach reply said, or the last resize sent. A repeat is
    /// dropped: the host re-sends its newest size on every connect (and one
    /// that does not suppress them reports again on pixel-only changes), and
    /// each would otherwise cost a message for a `TIOCSWINSZ` the kernel
    /// treats as a no-op.
    /// Forgotten with the connection, since a new one may reach a session
    /// this transport never sized.
    private var appliedViewport: (columns: Int, rows: Int)?
    private var _onEvent: (@Sendable (TerminalTransportEvent) -> Void)?
    private var _onSessionExit: (@Sendable (UInt64, Int32) -> Void)?

    /// Session to reattach to, if this transport is resuming a known one.
    private var resumeSessionID: UInt64?

    /// Absolute path of the shell to run, or `nil` to let the daemon pick.
    /// The daemon validates it (absolute, existing, executable) and rejects
    /// anything else — the app cannot talk it into running arbitrary bytes.
    private let shellPath: String?

    /// A live daemon session whose shell's current directory a fresh open
    /// starts in — the tab this one was opened from. Sent with the open
    /// only: an attach reaches a shell that already has a directory. The
    /// daemon reads the path from the kernel; the app never names one.
    private let inheritDirectoryFrom: UInt64?

    public var onEvent: (@Sendable (TerminalTransportEvent) -> Void)? {
        get { lock.locked { _onEvent } }
        set { lock.locked { _onEvent = newValue } }
    }

    /// The session's process exited on its own, as opposed to the link
    /// dropping or the host detaching. Carries the dead session's id and the
    /// exit status.
    ///
    /// A `.disconnected` event alone cannot express this: a detach, a daemon
    /// crash, and `exit` typed into the shell all produce one, and a reason
    /// string is for humans, not for branching on. A host that persists
    /// session ids for reattachment should forget the id here — after this
    /// fires, reattaching to it can only fail. Delivered on the transport
    /// queue, immediately before the matching `.disconnected`.
    public var onSessionExit: (@Sendable (UInt64, Int32) -> Void)? {
        get { lock.locked { _onSessionExit } }
        set { lock.locked { _onSessionExit = newValue } }
    }

    /// Shown to the user — a tab's title before the shell sets one, and the
    /// sidebar's subtitle — so it says "Session 7", not "ighostvtd session 7".
    /// The daemon-side id is what makes two untitled tabs tell apart.
    public var endpointDescription: String {
        lock.locked {
            guard let sessionID else {
                return String(localized: "Terminal")
            }
            return String.localizedStringWithFormat(
                NSLocalizedString("Session %lld", comment: "Tab title for a shell that has not set one"),
                Int(clamping: sessionID)
            )
        }
    }

    /// The daemon-side identifier, once open. Persist it to reattach later.
    public var currentSessionID: UInt64? {
        lock.locked { sessionID }
    }

    public init(
        shellPath: String? = nil,
        resumeSessionID: UInt64? = nil,
        inheritDirectoryFrom: UInt64? = nil
    ) {
        let trimmed = shellPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.shellPath = (trimmed?.isEmpty ?? true) ? nil : trimmed
        self.resumeSessionID = resumeSessionID
        self.inheritDirectoryFrom = inheritDirectoryFrom
    }

    deinit {
        // An activated XPC connection must be canceled before its last
        // reference goes away. Normal teardown already did this; the deinit
        // covers an owner that dropped the transport without disconnecting.
        if let connection = lock.locked({ self.connection }) {
            xpc_connection_cancel(connection)
        }
    }

    // Queued one-shot operations below capture `self` strongly on purpose.
    // The owner drops its reference immediately after asking for a close or
    // detach (`TerminalSessionStore.disconnect` nils the relay's transport),
    // and a `[weak self]` block then deallocates the transport before the
    // message is ever sent: the daemon keeps the shell attached forever, and
    // the still-activated XPC connection is released without a cancel. The
    // strong capture keeps the transport alive exactly until its queued work
    // — ending in `teardown`, which cancels the connection — has run.

    public func connect() {
        emit(.state(.connecting))
        queue.async {
            self.establish()
        }
    }

    public func send(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async {
            guard let link = self.attachedLink() else { return }
            let message = Self.makeMessage(.write, sessionID: link.sessionID)
            data.withUnsafeBytes { buffer in
                if let base = buffer.baseAddress {
                    xpc_dictionary_set_data(message, iGhostVTWireKey.data, base, buffer.count)
                }
            }
            xpc_connection_send_message(link.connection, message)
        }
    }

    /// Sizes the session, or records the size for the open to start at
    /// while there is none yet. The host calls this again on `.connected`,
    /// which is what carries a size reported during the open or attach
    /// round trip to the session: this transport never replays a size on
    /// its own, so a size captured before the trip can never outrank one
    /// reported during it.
    public func updateViewport(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        queue.async {
            self.latestViewport = (columns, rows)
            guard let link = self.attachedLink() else { return }
            self.sendResize(columns: columns, rows: rows, over: link)
        }
    }

    /// Runs on `queue`.
    private func sendResize(
        columns: Int, rows: Int, over link: (connection: xpc_connection_t, sessionID: UInt64)
    ) {
        if let applied = appliedViewport, applied.columns == columns, applied.rows == rows {
            return
        }
        appliedViewport = (columns, rows)
        let message = Self.makeMessage(.resize, sessionID: link.sessionID)
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.columns, UInt64(columns))
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.rows, UInt64(rows))
        xpc_connection_send_message(link.connection, message)
    }

    /// Detach without killing: the shell keeps running in the daemon.
    public func disconnect() {
        queue.async {
            if let link = self.attachedLink() {
                let message = Self.makeMessage(.detachSession, sessionID: link.sessionID)
                xpc_connection_send_message(link.connection, message)
            }
            self.teardown(reason: nil)
        }
    }

    /// End the session for good — the daemon terminates the shell.
    public func closeSession() {
        queue.async {
            guard let link = self.attachedLink() else { return }
            let message = Self.makeMessage(.closeSession, sessionID: link.sessionID)
            xpc_connection_send_message(link.connection, message)
            self.lock.locked { self.resumeSessionID = nil }
        }
    }

    /// One daemon-held session, as `listSessions` reports it. The daemon is
    /// the only book of record — the app deliberately persists nothing.
    public struct SessionSummary: Equatable, Sendable {
        public let id: UInt64
        public let title: String
        public let columns: UInt16
        public let rows: UInt16
        public let isAttached: Bool
    }

    /// Ask the daemon what it is holding, over a one-shot connection of its
    /// own. Completion fires exactly once, on an arbitrary queue: rows on
    /// success, nil when the daemon is unreachable or does not answer within
    /// the timeout (a hung daemon must not hang cold launch with it).
    public static func listSessions(
        timeout: TimeInterval = 6,
        completion: @escaping @Sendable ([SessionSummary]?) -> Void
    ) {
        let queue = DispatchQueue(label: "wiki.qaq.ighostvt.client.list", qos: .userInitiated)
        let finished = FinishOnce(completion)
        guard let rawConnection = iGhostVTProtocol.serviceName.withCString({
            ighostvtCreateMachServiceConnection($0, queue, 0)
        }) else {
            finished.finish(nil)
            return
        }
        // Boxed so the reply and timeout closures can carry it across the
        // Sendable boundary; all use stays on the one serial `queue`.
        let link = XPCConnectionBox(rawConnection)
        xpc_connection_set_event_handler(link.connection) { _ in }
        xpc_connection_activate(link.connection)
        queue.asyncAfter(deadline: .now() + timeout) {
            if finished.finish(nil) {
                xpc_connection_cancel(link.connection)
            }
        }
        xpc_connection_send_message_with_reply(link.connection, makeMessage(.hello), queue) { reply in
            guard Self.replyCode(of: reply) == .success else {
                if finished.finish(nil) {
                    xpc_connection_cancel(link.connection)
                }
                return
            }
            xpc_connection_send_message_with_reply(
                link.connection, makeMessage(.listSessions), queue
            ) { reply in
                xpc_connection_cancel(link.connection)
                finished.finish(Self.sessions(in: reply))
            }
        }
    }

    /// The rows of a `listSessions` reply; nil for anything but a success.
    private static func sessions(in reply: xpc_object_t) -> [SessionSummary]? {
        guard replyCode(of: reply) == .success,
              let array = xpc_dictionary_get_value(reply, iGhostVTWireKey.sessions),
              xpc_get_type(array) == XPC_TYPE_ARRAY
        else { return nil }
        var rows: [SessionSummary] = []
        for index in 0 ..< xpc_array_get_count(array) {
            let entry = xpc_array_get_value(array, index)
            guard xpc_get_type(entry) == XPC_TYPE_DICTIONARY else { continue }
            let title = xpc_dictionary_get_string(entry, iGhostVTWireKey.title)
                .map { String(cString: $0) } ?? ""
            rows.append(SessionSummary(
                id: xpc_dictionary_get_uint64(entry, iGhostVTWireKey.sessionID),
                title: title,
                columns: UInt16(truncatingIfNeeded: xpc_dictionary_get_uint64(entry, iGhostVTWireKey.columns)),
                rows: UInt16(truncatingIfNeeded: xpc_dictionary_get_uint64(entry, iGhostVTWireKey.rows)),
                isAttached: xpc_dictionary_get_bool(entry, iGhostVTWireKey.isAttached)
            ))
        }
        return rows
    }

    /// Kill a session over a connection of its own, for when the tab's
    /// transport has none — a failed connect, a detach, a daemon restart.
    /// Without this the kill silently goes nowhere, the shell outlives its
    /// tab forever, and each one counts against the daemon's session
    /// ceiling. `closeSession` is valid on any session the daemon knows,
    /// attached or not; an `unknownSession` reply means it is already gone,
    /// so no reply needs handling.
    public static func killSession(_ id: UInt64) {
        let queue = DispatchQueue(label: "wiki.qaq.ighostvt.client.kill", qos: .utility)
        guard let connection = iGhostVTProtocol.serviceName.withCString({
            ighostvtCreateMachServiceConnection($0, queue, 0)
        }) else { return }
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_activate(connection)
        xpc_connection_send_message_with_reply(connection, makeMessage(.hello), queue) { _ in
            let message = Self.makeMessage(.closeSession, sessionID: id)
            xpc_connection_send_message_with_reply(connection, message, queue) { _ in
                xpc_connection_cancel(connection)
            }
        }
    }

    /// The quit path. Kills `ids` (every session the daemon holds, attached
    /// or not, when nil), waits for the daemon to report each one *gone* —
    /// the close reply says only that the SIGHUP was sent, and a shell has
    /// up to the daemon's two-second grace to leave — and then, if asked and
    /// only if the daemon is left holding nothing at all, tells it to exit.
    /// A session kept on purpose is still in the list, so it alone is what
    /// keeps the daemon up; the daemon refuses the exit on its own count
    /// too, so a session opened by a window this app never saw is safe
    /// either way.
    ///
    /// Blocking on purpose, bounded by `timeout` for the whole sequence:
    /// the one caller is `applicationWillTerminate`, where anything still
    /// queued dies with the process. The tabs' own transports cannot do
    /// this — `closeSession` there is fire-and-forget on a queue the exit
    /// would outrun, and the disconnect that follows drops the connection
    /// the exit event would have arrived on.
    public static func closeSessionsForQuit(
        _ ids: [UInt64]?,
        stopDaemonWhenEmpty: Bool,
        timeout: TimeInterval = 3
    ) {
        let deadline = DispatchTime.now() + timeout
        let queue = DispatchQueue(label: "wiki.qaq.ighostvt.client.quit", qos: .userInitiated)
        guard let connection = iGhostVTProtocol.serviceName.withCString({
            ighostvtCreateMachServiceConnection($0, queue, 0)
        }) else { return }
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_activate(connection)
        let done = DispatchGroup()
        done.enter()
        func finish() {
            xpc_connection_cancel(connection)
            done.leave()
        }
        func list(_ completion: @escaping ([SessionSummary]?) -> Void) {
            xpc_connection_send_message_with_reply(connection, makeMessage(.listSessions), queue) { reply in
                completion(Self.sessions(in: reply))
            }
        }
        // Polls the daemon's list until none of `targets` remain, or the
        // deadline passes; hands over the last list either way.
        func awaitGone(_ targets: Set<UInt64>, then: @escaping ([SessionSummary]) -> Void) {
            list { rows in
                guard let rows else { return finish() }
                if !rows.contains(where: { targets.contains($0.id) }) || DispatchTime.now() >= deadline {
                    return then(rows)
                }
                queue.asyncAfter(deadline: .now() + .milliseconds(100)) {
                    awaitGone(targets, then: then)
                }
            }
        }
        xpc_connection_send_message_with_reply(connection, makeMessage(.hello), queue) { reply in
            guard Self.replyCode(of: reply) == .success else { return finish() }
            list { rows in
                guard let rows else { return finish() }
                let held = Set(rows.map(\.id))
                let targets = ids.map { held.intersection($0) } ?? held
                let kills = DispatchGroup()
                for id in targets {
                    kills.enter()
                    let message = Self.makeMessage(.closeSession, sessionID: id)
                    xpc_connection_send_message_with_reply(connection, message, queue) { _ in
                        kills.leave()
                    }
                }
                kills.notify(queue: queue) {
                    awaitGone(targets) { remaining in
                        guard stopDaemonWhenEmpty, remaining.isEmpty else { return finish() }
                        xpc_connection_send_message_with_reply(
                            connection, makeMessage(.shutdown), queue
                        ) { _ in
                            finish()
                        }
                    }
                }
            }
        }
        _ = done.wait(timeout: deadline)
    }

    // MARK: - Connection lifecycle

    private func establish() {
        guard let connection = iGhostVTProtocol.serviceName.withCString({
            ighostvtCreateMachServiceConnection($0, queue, 0)
        }) else {
            emit(.state(.disconnected(
                reason: String(localized: "The terminal helper is not running. Restart iGhostVT and try again.")
            )))
            return
        }

        lock.locked { self.connection = connection }
        xpc_connection_set_event_handler(connection) { [weak self] event in
            autoreleasepool {
                self?.handle(event)
            }
        }
        xpc_connection_activate(connection)

        let hello = Self.makeMessage(.hello)
        xpc_connection_send_message_with_reply(connection, hello, queue) { [weak self] reply in
            guard let self else { return }
            guard self.replyCode(reply) == .success else {
                self.teardown(
                    reason: String(localized: "Unable to connect to the terminal helper. Restart iGhostVT and try again.")
                )
                return
            }
            self.openOrAttachSession()
        }
    }

    private func openOrAttachSession() {
        guard let connection = lock.locked({ self.connection }) else { return }
        if let resumeSessionID = lock.locked({ self.resumeSessionID }) {
            let message = Self.makeMessage(.attachSession)
            xpc_dictionary_set_uint64(message, iGhostVTWireKey.sessionID, resumeSessionID)
            xpc_connection_send_message_with_reply(connection, message, queue) { [weak self] reply in
                guard let self else { return }
                if self.replyCode(reply) == .success {
                    self.lock.locked { self.sessionID = resumeSessionID }
                    // The attach carried no size; the reply says which one
                    // the session kept, so the host's re-send on
                    // `.connected` costs nothing when the grid is unchanged.
                    let columns = Int(xpc_dictionary_get_uint64(reply, iGhostVTWireKey.columns))
                    let rows = Int(xpc_dictionary_get_uint64(reply, iGhostVTWireKey.rows))
                    self.appliedViewport = columns > 0 && rows > 0 ? (columns, rows) : nil
                    self.emit(.state(.connected))
                    self.emitForegroundProcess(in: reply)
                    // Replayed scrollback so the surface rebuilds its screen.
                    // Repainted from a clean slate: on an in-app reconnect the
                    // surface still shows the session's last frame, and
                    // appending the whole replay below it reprints history the
                    // screen already has. Home + erase-display gives the
                    // replay the blank canvas a cold launch gets, and is a
                    // no-op on one.
                    if let replay = Self.data(iGhostVTWireKey.data, in: reply), !replay.isEmpty {
                        var payload = Data("\u{1B}[H\u{1B}[2J".utf8)
                        payload.append(replay)
                        self.emit(.received(payload))
                    }
                } else {
                    // The session is gone: scrub the dead ID everywhere
                    // before falling back to a fresh shell. Leaving it in
                    // the ledger means the Live Activity forever counts a
                    // detached shell the daemon no longer has.
                    self.lock.locked { self.resumeSessionID = nil }
                    self.onSessionExit?(resumeSessionID, -1)
                    self.openSession()
                }
            }
            return
        }
        openSession()
    }

    /// Runs on `queue`. Spawns at the grid reported so far — read here, not
    /// by the caller, since a failed attach reaches this after a round trip
    /// during which the surface may well have reported again.
    private func openSession() {
        guard let connection = lock.locked({ self.connection }) else { return }
        let columns = UInt64(latestViewport?.columns ?? Int(iGhostVTProtocol.defaultColumns))
        let rows = UInt64(latestViewport?.rows ?? Int(iGhostVTProtocol.defaultRows))
        let message = Self.makeMessage(.openSession)
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.columns, columns)
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.rows, rows)
        if let shellPath {
            // Just the path: the daemon decides the argv and the login
            // environment that goes with it.
            let command = xpc_array_create(nil, 0)
            xpc_array_set_string(command, XPC_ARRAY_APPEND, shellPath)
            xpc_dictionary_set_value(message, iGhostVTWireKey.command, command)
        }
        if let inheritDirectoryFrom {
            xpc_dictionary_set_uint64(message, iGhostVTWireKey.inheritDirectoryFrom, inheritDirectoryFrom)
        }
        xpc_connection_send_message_with_reply(connection, message, queue) { [weak self] reply in
            guard let self else { return }
            let code = self.replyCode(reply)
            guard code == .success else {
                self.teardown(reason: Self.failureReason(reply, code: code))
                return
            }
            let sessionID = xpc_dictionary_get_uint64(reply, iGhostVTWireKey.sessionID)
            self.lock.locked {
                self.sessionID = sessionID
                self.resumeSessionID = sessionID
            }
            self.appliedViewport = (Int(columns), Int(rows))
            self.emit(.state(.connected))
            self.emitForegroundProcess(in: reply)
        }
    }

    private func handle(_ event: xpc_object_t) {
        let type = xpc_get_type(event)
        if type == XPC_TYPE_ERROR {
            // The link died out from under us — daemon restart, not a
            // session end. The resume ID survives, so a reconnect can
            // reattach to the still-running shell. A cancel this transport
            // performed itself also surfaces here as one last error event;
            // the connection is already forgotten then, and it must not be
            // reported as an interruption.
            guard dropConnection() else { return }
            emit(.state(.interrupted(
                reason: String(localized: "The terminal connection was interrupted. Try again.")
            )))
            return
        }
        guard type == XPC_TYPE_DICTIONARY,
              xpc_dictionary_get_uint64(event, iGhostVTWireKey.version) == iGhostVTProtocol.version,
              let pushed = iGhostVTEvent(
                  rawValue: xpc_dictionary_get_uint64(event, iGhostVTWireKey.event)
              )
        else { return }

        let eventSessionID = xpc_dictionary_get_uint64(event, iGhostVTWireKey.sessionID)
        guard eventSessionID == lock.locked({ sessionID }) else { return }

        switch pushed {
        case .output:
            if let data = Self.data(iGhostVTWireKey.data, in: event), !data.isEmpty {
                emit(.received(data))
            }
        case .processName:
            emitForegroundProcess(in: event)
        case .sessionExit:
            let exitCode = Int32(
                truncatingIfNeeded: xpc_dictionary_get_int64(event, iGhostVTWireKey.exitCode)
            )
            // The id is dead: clear it before anyone can try to resume it.
            lock.locked { resumeSessionID = nil }
            onSessionExit?(eventSessionID, exitCode)
            teardown(
                reason: exitCode == 0
                    ? String(localized: "The shell exited.")
                    : String.localizedStringWithFormat(
                        NSLocalizedString(
                            "The shell exited with status %lld.",
                            comment: "Why a terminal stopped; %lld is the process exit status"
                        ),
                        Int(exitCode)
                    )
            )
        }
    }

    private func teardown(reason: String?) {
        guard dropConnection() else { return }
        emit(.state(.disconnected(reason: reason)))
    }

    /// Cancels and forgets the connection, keeping the resume ID. Returns
    /// false when there was nothing to drop.
    @discardableResult
    private func dropConnection() -> Bool {
        let connection: xpc_connection_t? = lock.locked {
            let current = self.connection
            self.connection = nil
            self.sessionID = nil
            return current
        }
        // Still on `queue`: the connection targets it, so its error events
        // and every reply arrive there, and each other caller is a block on
        // it.
        appliedViewport = nil
        guard let connection else { return false }
        xpc_connection_cancel(connection)
        return true
    }

    /// The connection and its session id read together, so a teardown between
    /// two reads cannot pair a stale connection with a fresh id.
    private func attachedLink() -> (connection: xpc_connection_t, sessionID: UInt64)? {
        lock.locked {
            guard let connection = self.connection,
                  let sessionID = self.sessionID else { return nil }
            return (connection, sessionID)
        }
    }

    // MARK: - Wire helpers

    private static func makeMessage(_ operation: iGhostVTOperation) -> xpc_object_t {
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.version, iGhostVTProtocol.version)
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.operation, operation.rawValue)
        return message
    }

    private static func makeMessage(_ operation: iGhostVTOperation, sessionID: UInt64) -> xpc_object_t {
        let message = makeMessage(operation)
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.sessionID, sessionID)
        return message
    }

    private func replyCode(_ reply: xpc_object_t) -> iGhostVTReplyCode {
        Self.replyCode(of: reply)
    }

    private static func replyCode(of reply: xpc_object_t) -> iGhostVTReplyCode {
        guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY,
              xpc_dictionary_get_uint64(reply, iGhostVTWireKey.version) == iGhostVTProtocol.version,
              let code = iGhostVTReplyCode(
                  rawValue: xpc_dictionary_get_int64(reply, iGhostVTWireKey.code)
              )
        else { return .operationFailed }
        return code
    }

    private func emit(_ event: TerminalTransportEvent) {
        onEvent?(event)
    }

    /// The foreground process as a reply or event 102 states it. An older
    /// daemon sends no shell flag; `get_bool` reads false for the missing
    /// key, which the app treats as "something may be running" — the
    /// safe side.
    private func emitForegroundProcess(in dictionary: xpc_object_t) {
        guard let name = Self.string(iGhostVTWireKey.processName, in: dictionary) else { return }
        let isShell = xpc_dictionary_get_bool(dictionary, iGhostVTWireKey.foregroundIsShell)
        emit(.processName(name, isShell: isShell))
    }

    private static func string(_ key: String, in dictionary: xpc_object_t) -> String? {
        guard xpc_get_type(dictionary) == XPC_TYPE_DICTIONARY,
              let value = xpc_dictionary_get_string(dictionary, key)
        else { return nil }
        return String(cString: value)
    }

    private static func data(_ key: String, in dictionary: xpc_object_t) -> Data? {
        guard xpc_get_type(dictionary) == XPC_TYPE_DICTIONARY else { return nil }
        var count = 0
        guard let bytes = xpc_dictionary_get_data(dictionary, key, &count),
              count <= iGhostVTProtocol.maximumMessageDataByteCount else { return nil }
        return Data(bytes: bytes, count: count)
    }

    /// The daemon's own sentence when it sent one — it knows which shell it
    /// tried and what the system said, and only the reply code survives
    /// otherwise. Falls back to the generic wording for a code with no detail.
    private static func failureReason(_ reply: xpc_object_t, code: iGhostVTReplyCode) -> String {
        guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY,
              let message = xpc_dictionary_get_string(reply, iGhostVTWireKey.errorMessage)
        else { return describe(code) }
        let text = String(cString: message)
        return text.isEmpty ? describe(code) : text
    }

    private static func describe(_ code: iGhostVTReplyCode) -> String {
        switch code {
        // `.success` never reaches here — both callers describe a failure —
        // so it takes the generic wording rather than inventing a sentence
        // that would read as nonsense in an error card.
        case .success, .operationFailed:
            String(localized: "Unable to complete this action. Try again.")
        case .invalidRequest: String(localized: "Unable to complete this action. Try again.")
        case .unsupportedVersion:
            String(localized: "iGhostVT and its terminal helper are different versions. Reinstall iGhostVT to update both.")
        case .handshakeRequired: String(localized: "The terminal connection is not ready. Try again.")
        case .sessionLimitReached: String(localized: "Too many terminals are open. Close one and try again.")
        case .unknownSession: String(localized: "This terminal no longer exists.")
        case .sessionBusy: String(localized: "This terminal is already open in another window.")
        case .spawnFailed: String(localized: "No usable shell was found. Check the default shell in Settings.")
        }
    }
}

private extension NSLock {
    func locked<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

/// Carries an xpc_connection_t across Sendable closure boundaries. XPC
/// objects are thread-safe; the annotation is what the type system lacks.
private final class XPCConnectionBox: @unchecked Sendable {
    let connection: xpc_connection_t
    init(_ connection: xpc_connection_t) {
        self.connection = connection
    }
}

/// Guarantees a completion fires exactly once across the reply, error, and
/// timeout paths of a one-shot query. `finish` returns whether this call won.
private final class FinishOnce<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (Value) -> Void)?

    init(_ completion: @escaping @Sendable (Value) -> Void) {
        self.completion = completion
    }

    @discardableResult
    func finish(_ value: Value) -> Bool {
        lock.lock()
        let completion = completion
        self.completion = nil
        lock.unlock()
        guard let completion else { return false }
        completion(value)
        return true
    }
}
