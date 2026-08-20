import Combine
import Foundation
import GhosttyTerminal
import iGhosttyKit
import os

/// Glues a `TerminalTransport` to libghostty's host-managed terminal session.
///
/// Bytes the terminal produces (keystrokes) go out through the transport;
/// bytes the transport receives are fed back into the terminal. Connection
/// status is echoed into the terminal itself as dim status lines, so the
/// surface doubles as the connection log.
@MainActor
final class TerminalSessionStore: ObservableObject {
    /// The whole session pipeline logs here (`log stream --process iGhostty`)
    /// because a black surface has no other way to say where it stopped:
    /// no viewport line means the surface never attached, no connect line
    /// means the transport was never asked.
    static let logger = Logger(subsystem: "wiki.qaq.iGhostty", category: "session")

    enum Status: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var status: Status = .idle

    /// Exit status of the session's process once it has ended, nil while it
    /// lives (or before it ever ran). Branches the failure card: an exited
    /// shell is an outcome to acknowledge, a lost daemon is an error to
    /// retry. Set through the tab's transport wiring — the transport's exit
    /// event is the only trustworthy signal, reason strings are for humans.
    @Published private(set) var processExitStatus: Int32?

    /// Title guessed from the last command the user typed, used only while
    /// the shell reports none of its own. Empty until a command is accepted.
    ///
    /// See ``CommandTitleTracker``: the tracker offers a line, this decides
    /// whether it made it to the screen. An unechoed line — a password, a
    /// key a full-screen program swallowed — never becomes a title.
    @Published private(set) var inferredTitle: String = ""

    /// Latest grid size reported by the surface; forwarded to the transport,
    /// which decides whether it can carry it.
    private(set) var viewport: (columns: Int, rows: Int)?

    let session: InMemoryTerminalSession
    private let relay = TransportRelay()
    private let titleTracker = CommandTitleTracker()
    private var hasAutoConnected = false
    private let makeTransport: () -> TerminalTransport

    /// Reconnect-after-interruption state. The daemon may still hold the
    /// session when the link drops (its KeepAlive restart, mostly), so a few
    /// paced attempts reattach and resume before anything is declared failed.
    /// The generation invalidates a scheduled attempt when the user connects
    /// or disconnects by hand in the meantime.
    private var reconnectAttempt = 0
    private var reconnectGeneration: UInt64 = 0
    private static let reconnectAttemptLimit = 5
    private static let reconnectDelay: UInt64 = 1_000_000_000

    /// The transport of the current connection, for callers that need
    /// implementation-specific capability (daemon session control).
    var activeTransport: TerminalTransport? { relay.transport }

    /// Where this session's bytes go, for titles and the sidebar subtitle.
    var endpointDescription: String {
        relay.transport?.endpointDescription ?? String(localized: "Terminal")
    }

    /// The transport factory is the backend seam: tabs hand in the daemon
    /// transport today, and an SSH-backed session swaps the factory without
    /// touching the store, the tabs, or the interface.
    init(makeTransport: @escaping () -> TerminalTransport) {
        self.makeTransport = makeTransport

        let relay = relay
        let titleTracker = titleTracker
        session = InMemoryTerminalSession(
            write: { data in
                relay.send(data)
                titleTracker.consume(data)
            },
            resize: { viewport in
                relay.updateViewport(
                    columns: Int(viewport.columns),
                    rows: Int(viewport.rows)
                )
            }
        )
        relay.onViewportChange = { [weak self] columns, rows in
            Task { @MainActor [weak self] in
                self?.handleViewportChange(columns: columns, rows: rows)
            }
        }
        titleTracker.onCommand = { [weak self] command in
            Task { @MainActor [weak self] in
                self?.offerInferredTitle(command)
            }
        }
    }

    /// Accepts a typed line as this session's title, if it is one.
    ///
    /// The viewport check is the safety half: the line has to be visible on
    /// screen at the moment Return was pressed. A prompt reading a password
    /// echoes nothing, so nothing here matches and the old title stands.
    private func offerInferredTitle(_ command: String) {
        let command = command.trimmingCharacters(in: .whitespaces)
        guard CommandTitleTracker.isPlausibleCommand(command),
              let screen = session.readViewportText(),
              screen.contains(command)
        else { return }
        inferredTitle = command
    }

    /// The first viewport report means the surface is attached and rendering,
    /// so bytes fed to the session are no longer dropped — the earliest safe
    /// moment to open the connection. It also means a transport that
    /// negotiates size knows the grid before connecting.
    private func handleViewportChange(columns: Int, rows: Int) {
        Self.logger.info("surface reported viewport \(columns)x\(rows)")
        viewport = (columns, rows)
        guard !hasAutoConnected else { return }
        hasAutoConnected = true
        // The first report lands mid launch-transition — a pane still
        // animating in briefly measures ~49×16 — and connecting right then
        // spawns (or resizes) the daemon-side PTY at that size. One short
        // beat lets layout settle; `connect()` primes the transport with
        // whatever the viewport is by then.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            self?.connect()
        }
    }

    func noteProcessExit(status: Int32) {
        processExitStatus = status
    }

    func connect() {
        reconnectGeneration &+= 1
        // A new connection means a new (or resumed) process; the old exit
        // verdict no longer describes this session.
        processExitStatus = nil
        // A half-typed line does not survive a reconnect: the shell's line
        // editor never saw the bytes that the dropped link ate.
        titleTracker.reset()
        let transport = makeTransport()
        Self.logger.info("connecting via \(transport.endpointDescription)")
        transport.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }
        relay.transport = transport
        // A reconnect's transport starts with no viewport of its own, and an
        // attach sizes the PTY before this store hears `.connected` — without
        // priming, the daemon briefly gets the 80×24 protocol default and the
        // shell redraws for a grid nobody has.
        if let viewport {
            transport.updateViewport(columns: viewport.columns, rows: viewport.rows)
        }
        transport.connect()
    }

    func disconnect() {
        reconnectGeneration &+= 1
        reconnectAttempt = 0
        relay.transport?.disconnect()
        relay.transport = nil
        status = .idle
    }

    private func handle(_ event: TerminalTransportEvent) {
        switch event {
        case let .received(data):
            session.receive(data)
        case let .state(state):
            apply(state)
        }
    }

    private func apply(_ state: TerminalTransportState) {
        switch state {
        case .connecting:
            // No status line: the pill overlay already says connecting, and
            // a clean launch should open on the shell's own first line.
            // Only trouble (interruptions, failures) gets written into the
            // terminal.
            status = .connecting
        case .connected:
            Self.logger.info("connected to \(self.endpointDescription)")
            status = .connected
            reconnectAttempt = 0
            if let viewport {
                relay.updateViewport(columns: viewport.columns, rows: viewport.rows)
            }
        case let .interrupted(reason):
            Self.logger.error("link lost: \(reason ?? "no reason")")
            printStatusLine("connection lost")
            scheduleReconnect(lastReason: reason)
        case let .disconnected(reason):
            Self.logger.error("disconnected: \(reason ?? "no reason")")
            // Mid-cycle this is a reconnect attempt that could not even
            // establish; keep trying until the attempts run out.
            if reconnectAttempt > 0 {
                scheduleReconnect(lastReason: reason)
                return
            }
            status = reason.map { .failed($0) } ?? .idle
            printStatusLine(reason.map { "disconnected: \($0)" } ?? "disconnected")
        }
    }

    /// One paced attempt to get the session back, or the final failure once
    /// the attempts are spent. Runs only after `interrupted` — a final
    /// `disconnected` never starts a cycle.
    private func scheduleReconnect(lastReason: String?) {
        guard reconnectAttempt < Self.reconnectAttemptLimit else {
            reconnectAttempt = 0
            let reason = lastReason ?? String(
                localized: "The connection to the terminal daemon could not be restored."
            )
            status = .failed(reason)
            printStatusLine("disconnected: \(reason)")
            return
        }
        reconnectAttempt += 1
        status = .connecting
        reconnectGeneration &+= 1
        let generation = reconnectGeneration
        Self.logger.info("reconnect attempt \(self.reconnectAttempt) scheduled")
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.reconnectDelay)
            guard let self, self.reconnectGeneration == generation else { return }
            self.connect()
        }
    }

    /// Dim, bracketed line rendered by the terminal itself.
    ///
    /// Opens with a bare `\r` rather than `\r\n`: consecutive status lines
    /// already end with a newline, so a leading one puts a blank line between
    /// every pair. The carriage return alone still guarantees column zero.
    private func printStatusLine(_ message: String) {
        session.receive("\r\u{1b}[2m[ighostty] \(message)\u{1b}[0m\r\n")
    }
}

/// Thread-safe indirection between the long-lived terminal session and the
/// transport of the moment. The session's write/resize closures are captured
/// once at init; reconnects swap the transport behind this relay.
private final class TransportRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var _transport: TerminalTransport?

    /// Observes viewport changes regardless of transport presence.
    var onViewportChange: (@Sendable (Int, Int) -> Void)?

    var transport: TerminalTransport? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _transport
        }
        set {
            lock.lock()
            _transport = newValue
            lock.unlock()
        }
    }

    func send(_ data: Data) {
        transport?.send(data)
    }

    func updateViewport(columns: Int, rows: Int) {
        onViewportChange?(columns, rows)
        transport?.updateViewport(columns: columns, rows: rows)
    }
}
