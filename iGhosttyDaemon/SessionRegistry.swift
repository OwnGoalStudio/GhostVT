import Darwin
import Dispatch
import Foundation
import os

/// The daemon's store of live terminal sessions.
///
/// Sessions belong to the registry, not to whichever connection created them,
/// so closing the app detaches rather than kills. A relaunched app lists what
/// is still running and reattaches to it.
final class SessionRegistry {
    private let queue: DispatchQueue
    private var sessions: [UInt64: PTYSession] = [:]
    private var attachments: [UInt64: PeerSession] = [:]
    private var nextID: UInt64 = 1
    private var childExitSignal: DispatchSourceSignal?

    init(queue: DispatchQueue) {
        self.queue = queue
        // The authoritative reaper under every session's own exit source
        // (see PTYSession.start for the kernel ordering): SIGCHLD is sent
        // once the child is waitable, coalesced and naming no pid, so every
        // live session gets asked. SIGCHLD stays SIG_DFL (main.swift): the
        // source observes delivery, and SIG_IGN would auto-reap.
        let signalSource = DispatchSource.makeSignalSource(signal: SIGCHLD, queue: queue)
        signalSource.setEventHandler { [weak self] in
            guard let self else { return }
            for session in self.sessions.values {
                session.reapIfExited()
            }
        }
        signalSource.activate()
        childExitSignal = signalSource
    }

    var summaries: [(id: UInt64, title: String, columns: UInt16, rows: UInt16, isAttached: Bool)] {
        sessions.values
            .sorted { $0.id < $1.id }
            .map {
                (
                    id: $0.id,
                    title: $0.command.first.map { path in
                        (path as NSString).lastPathComponent
                    } ?? "shell",
                    columns: $0.columns,
                    rows: $0.rows,
                    isAttached: attachments[$0.id] != nil
                )
            }
    }

    func session(_ id: UInt64) -> PTYSession? {
        sessions[id]
    }

    func open(
        command requestedCommand: [String],
        environment requestedEnvironment: [String: String],
        columns: UInt16,
        rows: UInt16
    ) throws -> PTYSession {
        guard sessions.count < iGhosttyProtocol.maximumSessions else {
            throw iGhosttyFailure(
                .sessionLimitReached,
                "the daemon is already holding \(sessions.count) sessions; close some before opening more"
            )
        }
        let plan = try resolvePlan(requestedCommand)
        let id = nextID
        nextID &+= 1

        let session = try PTYSession(
            id: id,
            command: plan.command,
            environment: plan.environment.merging(requestedEnvironment) { _, client in client },
            columns: clamp(columns, fallback: iGhosttyProtocol.defaultColumns, limit: iGhosttyProtocol.maximumColumns),
            rows: clamp(rows, fallback: iGhosttyProtocol.defaultRows, limit: iGhosttyProtocol.maximumRows),
            credentials: plan.credentials,
            workingDirectory: plan.workingDirectory,
            queue: queue
        )
        sessions[id] = session
        DaemonLog.sessions.info(
            "session \(id) spawned \(plan.command.first ?? "?", privacy: .public), \(self.sessions.count)/\(iGhosttyProtocol.maximumSessions) held"
        )
        DaemonFileLog.log(
            "session \(id) spawned \(plan.command.first ?? "?"), \(sessions.count)/\(iGhosttyProtocol.maximumSessions) held"
        )
        session.start(
            onOutput: { [weak self] sessionID, data in
                self?.attachments[sessionID]?.deliverOutput(sessionID: sessionID, data: data)
            },
            onExit: { [weak self] sessionID, exitCode in
                self?.handleExit(sessionID: sessionID, exitCode: exitCode)
            }
        )
        return session
    }

    func attach(_ id: UInt64, to peer: PeerSession) throws -> PTYSession {
        guard let session = sessions[id] else {
            throw iGhosttyReplyCode.unknownSession
        }
        if let existing = attachments[id], existing !== peer {
            throw iGhosttyReplyCode.sessionBusy
        }
        attachments[id] = peer
        return session
    }

    func detach(_ id: UInt64, from peer: PeerSession) {
        guard attachments[id] === peer else { return }
        attachments.removeValue(forKey: id)
    }

    func detachAll(for peer: PeerSession) {
        for (id, attached) in attachments where attached === peer {
            attachments.removeValue(forKey: id)
        }
    }

    /// How long a closed shell gets to exit on its own before it is killed.
    /// Long enough for a shell to run its exit hooks, short enough that the
    /// user never notices the session is still there.
    private static let closeGracePeriod: DispatchTimeInterval = .seconds(2)

    /// Explicit user-initiated close: the shell goes away for good, and so
    /// does everything the daemon was holding for it.
    ///
    /// `SIGHUP` alone is not a release. It is asynchronous, and a shell is
    /// free to ignore it — so the old "terminate and let the exit handler
    /// clean up" shape leaked the PTY, the replay buffer and the registry
    /// entry for any session that declined to die. Ask nicely, then take it.
    func close(_ id: UInt64) throws {
        guard let session = sessions[id] else {
            DaemonLog.sessions.info("close of session \(id): unknown, already gone")
            throw iGhosttyReplyCode.unknownSession
        }
        DaemonLog.sessions.info("session \(id) close requested, SIGHUP sent")
        session.terminate()
        queue.asyncAfter(deadline: .now() + Self.closeGracePeriod) { [weak self] in
            guard let self, self.sessions[id] === session else { return }
            self.handleExit(sessionID: id, exitCode: 128 + SIGKILL)
        }
    }

    // MARK: - Internals

    /// Drops a session, telling whoever is still attached — otherwise the app
    /// keeps a tab pointing at a session the daemon no longer has.
    private func handleExit(sessionID: UInt64, exitCode: Int32) {
        DaemonLog.sessions.info(
            "session \(sessionID) exited with status \(exitCode), \(self.sessions.count - 1) remain"
        )
        DaemonFileLog.log(
            "session \(sessionID) exited with status \(exitCode), \(sessions.count - 1) remain"
        )
        attachments[sessionID]?.deliverExit(sessionID: sessionID, exitCode: exitCode)
        discard(sessionID)
    }

    /// The only way a session leaves the registry. `invalidate()` cancels the
    /// dispatch sources, kills the child if it is somehow still alive, and
    /// closes the master — and dropping the last reference frees the replay
    /// buffer with it.
    private func discard(_ id: UInt64) {
        attachments.removeValue(forKey: id)
        sessions.removeValue(forKey: id)?.invalidate()
    }

    /// A client sends either nothing (give me a shell), a single path (give me
    /// *this* shell), or a full argv it wants run verbatim.
    private func resolvePlan(_ requested: [String]) throws -> ShellLaunch.Plan {
        switch requested.count {
        case 0:
            guard let plan = ShellLaunch.plan(requestedShell: nil) else {
                throw iGhosttyFailure(
                    .spawnFailed,
                    "no usable shell: neither the bootstrap's passwd shell nor a fallback shell is executable"
                )
            }
            return plan
        case 1:
            guard let plan = ShellLaunch.plan(requestedShell: requested[0]) else {
                throw iGhosttyFailure(
                    .invalidRequest,
                    "the configured shell \(requested[0]) is not an executable absolute path"
                )
            }
            return plan
        default:
            guard let command = ShellLaunch.validate(requested) else {
                throw iGhosttyFailure(
                    .invalidRequest,
                    "the requested command is not an executable absolute path"
                )
            }
            return ShellLaunch.verbatimPlan(command: command)
        }
    }

    private func clamp(_ value: UInt16, fallback: UInt16, limit: UInt16) -> UInt16 {
        guard value > 0 else { return fallback }
        return min(value, limit)
    }
}

extension iGhosttyReplyCode: Error {}
