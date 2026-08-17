import Darwin
import Dispatch
import Foundation
import os
import XPC

/// One authenticated client connection.
///
/// Requests arrive here and are answered on the control queue; output flows
/// the other way as unsolicited messages on the same connection. A peer holds
/// no session state of its own — it attaches to sessions the registry owns.
final class PeerSession {
    private let connection: xpc_connection_t
    private let clientPID: Int32
    private let queue: DispatchQueue
    private let registry: SessionRegistry
    private let onInvalidate: (PeerSession) -> Void

    private var didHandshake = false
    private var attachedSessionIDs: Set<UInt64> = []
    private var isValid = true

    init(
        connection: xpc_connection_t,
        clientPID: Int32,
        queue: DispatchQueue,
        registry: SessionRegistry,
        onInvalidate: @escaping (PeerSession) -> Void
    ) {
        self.connection = connection
        self.clientPID = clientPID
        self.queue = queue
        self.registry = registry
        self.onInvalidate = onInvalidate
    }

    func activate() {
        xpc_connection_set_target_queue(connection, queue)
        xpc_connection_set_event_handler(connection) { [weak self] event in
            autoreleasepool {
                self?.handle(event)
            }
        }
        xpc_connection_activate(connection)
    }

    // MARK: - Output toward the client

    func deliverOutput(sessionID: UInt64, data: Data) {
        guard isValid else { return }
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(message, iGhosttyWireKey.version, iGhosttyProtocol.version)
        xpc_dictionary_set_uint64(message, iGhosttyWireKey.event, iGhosttyEvent.output.rawValue)
        xpc_dictionary_set_uint64(message, iGhosttyWireKey.sessionID, sessionID)
        data.withUnsafeBytes { buffer in
            if let base = buffer.baseAddress {
                xpc_dictionary_set_data(message, iGhosttyWireKey.data, base, buffer.count)
            }
        }
        xpc_connection_send_message(connection, message)
    }

    func deliverExit(sessionID: UInt64, exitCode: Int32) {
        guard isValid else { return }
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(message, iGhosttyWireKey.version, iGhosttyProtocol.version)
        xpc_dictionary_set_uint64(message, iGhosttyWireKey.event, iGhosttyEvent.sessionExit.rawValue)
        xpc_dictionary_set_uint64(message, iGhosttyWireKey.sessionID, sessionID)
        xpc_dictionary_set_int64(message, iGhosttyWireKey.exitCode, Int64(exitCode))
        xpc_connection_send_message(connection, message)
        attachedSessionIDs.remove(sessionID)
    }

    // MARK: - Requests from the client

    private func handle(_ event: xpc_object_t) {
        let type = xpc_get_type(event)
        if type == XPC_TYPE_ERROR {
            invalidate()
            return
        }
        guard type == XPC_TYPE_DICTIONARY else { return }

        let reply = xpc_dictionary_create_reply(event)
        let code = process(event, reply: reply)
        guard let reply else { return }
        xpc_dictionary_set_uint64(reply, iGhosttyWireKey.version, iGhosttyProtocol.version)
        xpc_dictionary_set_int64(reply, iGhosttyWireKey.code, code.rawValue)
        xpc_connection_send_message(connection, reply)
    }

    private func process(_ message: xpc_object_t, reply: xpc_object_t?) -> iGhosttyReplyCode {
        guard xpc_dictionary_get_uint64(message, iGhosttyWireKey.version) == iGhosttyProtocol.version else {
            return .unsupportedVersion
        }
        guard let operation = iGhosttyOperation(
            rawValue: xpc_dictionary_get_uint64(message, iGhosttyWireKey.operation)
        ) else {
            return .invalidRequest
        }
        guard didHandshake || operation == .hello else {
            return .handshakeRequired
        }

        switch operation {
        case .hello:
            didHandshake = true
            return .success
        case .listSessions:
            return listSessions(into: reply)
        case .openSession:
            return openSession(message, reply: reply)
        case .attachSession:
            return attachSession(message, reply: reply)
        case .detachSession:
            return detachSession(message)
        case .write:
            return write(message)
        case .resize:
            return resize(message)
        case .closeSession:
            return closeSession(message)
        case .goodbye:
            queue.async { [weak self] in self?.invalidate() }
            return .success
        }
    }

    private func listSessions(into reply: xpc_object_t?) -> iGhosttyReplyCode {
        guard let reply else { return .success }
        let summaries = registry.summaries
        let array = xpc_array_create(nil, 0)
        for summary in summaries {
            let entry = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_uint64(entry, iGhosttyWireKey.sessionID, summary.id)
            xpc_dictionary_set_string(entry, iGhosttyWireKey.title, summary.title)
            xpc_dictionary_set_uint64(entry, iGhosttyWireKey.columns, UInt64(summary.columns))
            xpc_dictionary_set_uint64(entry, iGhosttyWireKey.rows, UInt64(summary.rows))
            xpc_dictionary_set_bool(entry, iGhosttyWireKey.isAttached, summary.isAttached)
            xpc_array_append_value(array, entry)
        }
        xpc_dictionary_set_value(reply, iGhosttyWireKey.sessions, array)
        return .success
    }

    private func openSession(_ message: xpc_object_t, reply: xpc_object_t?) -> iGhosttyReplyCode {
        guard attachedSessionIDs.count < iGhosttyProtocol.maximumSessionsPerPeer else {
            return .sessionLimitReached
        }
        let command = stringArray(message, key: iGhosttyWireKey.command)
        let environment = stringDictionary(message, key: iGhosttyWireKey.environment)
        let columns = UInt16(truncatingIfNeeded: xpc_dictionary_get_uint64(message, iGhosttyWireKey.columns))
        let rows = UInt16(truncatingIfNeeded: xpc_dictionary_get_uint64(message, iGhosttyWireKey.rows))

        do {
            let session = try registry.open(
                command: command,
                environment: environment,
                columns: columns,
                rows: rows
            )
            _ = try registry.attach(session.id, to: self)
            attachedSessionIDs.insert(session.id)
            if let reply {
                xpc_dictionary_set_uint64(reply, iGhosttyWireKey.sessionID, session.id)
            }
            return .success
        } catch let failure as iGhosttyFailure {
            // The app shows this verbatim, so a session that never started can
            // say which shell it tried and what the system answered.
            DaemonLog.sessions.error(
                "open for peer \(self.clientPID) failed: \(failure.message, privacy: .public)"
            )
            if let reply {
                xpc_dictionary_set_string(reply, iGhosttyWireKey.errorMessage, failure.message)
            }
            return failure.code
        } catch let code as iGhosttyReplyCode {
            DaemonLog.sessions.error(
                "open for peer \(self.clientPID) failed: reply code \(code.rawValue)"
            )
            return code
        } catch {
            return .spawnFailed
        }
    }

    private func attachSession(_ message: xpc_object_t, reply: xpc_object_t?) -> iGhosttyReplyCode {
        let id = xpc_dictionary_get_uint64(message, iGhosttyWireKey.sessionID)
        do {
            let session = try registry.attach(id, to: self)
            attachedSessionIDs.insert(id)
            if let reply {
                xpc_dictionary_set_uint64(reply, iGhosttyWireKey.columns, UInt64(session.columns))
                xpc_dictionary_set_uint64(reply, iGhosttyWireKey.rows, UInt64(session.rows))
                let replay = session.replayData()
                replay.withUnsafeBytes { buffer in
                    if let base = buffer.baseAddress, !replay.isEmpty {
                        xpc_dictionary_set_data(reply, iGhosttyWireKey.data, base, buffer.count)
                    }
                }
            }
            DaemonLog.sessions.info("peer \(self.clientPID) attached session \(id)")
            return .success
        } catch let code as iGhosttyReplyCode {
            DaemonLog.sessions.error(
                "attach session \(id) for peer \(self.clientPID) failed: reply code \(code.rawValue)"
            )
            return code
        } catch {
            return .operationFailed
        }
    }

    private func detachSession(_ message: xpc_object_t) -> iGhosttyReplyCode {
        let id = xpc_dictionary_get_uint64(message, iGhosttyWireKey.sessionID)
        registry.detach(id, from: self)
        attachedSessionIDs.remove(id)
        DaemonLog.sessions.info("peer \(self.clientPID) detached session \(id)")
        return .success
    }

    private func write(_ message: xpc_object_t) -> iGhosttyReplyCode {
        let id = xpc_dictionary_get_uint64(message, iGhosttyWireKey.sessionID)
        guard attachedSessionIDs.contains(id), let session = registry.session(id) else {
            return .unknownSession
        }
        var count = 0
        guard let bytes = xpc_dictionary_get_data(message, iGhosttyWireKey.data, &count),
              count <= iGhosttyProtocol.maximumMessageDataByteCount else {
            return .invalidRequest
        }
        session.write(Data(bytes: bytes, count: count))
        return .success
    }

    private func resize(_ message: xpc_object_t) -> iGhosttyReplyCode {
        let id = xpc_dictionary_get_uint64(message, iGhosttyWireKey.sessionID)
        guard attachedSessionIDs.contains(id), let session = registry.session(id) else {
            return .unknownSession
        }
        let columns = xpc_dictionary_get_uint64(message, iGhosttyWireKey.columns)
        let rows = xpc_dictionary_get_uint64(message, iGhosttyWireKey.rows)
        guard columns > 0, columns <= UInt64(iGhosttyProtocol.maximumColumns),
              rows > 0, rows <= UInt64(iGhosttyProtocol.maximumRows) else {
            return .invalidRequest
        }
        session.resize(columns: UInt16(columns), rows: UInt16(rows))
        return .success
    }

    private func closeSession(_ message: xpc_object_t) -> iGhosttyReplyCode {
        // Deliberately not gated on being attached. A tab whose connection
        // dropped still has to be closable, and requiring an attach first
        // meant the app silently skipped the kill for exactly those tabs —
        // the shell then lived on with nothing left to reach it. Every peer
        // here already passed audit-token authentication and can see every
        // session through `listSessions`, so closing one it did not open is
        // no more privilege than it already had.
        let id = xpc_dictionary_get_uint64(message, iGhosttyWireKey.sessionID)
        do {
            try registry.close(id)
            attachedSessionIDs.remove(id)
            return .success
        } catch let code as iGhosttyReplyCode {
            return code
        } catch {
            return .operationFailed
        }
    }

    private func invalidate() {
        guard isValid else { return }
        isValid = false
        // Sessions survive: the client going away is a detach, not a kill.
        registry.detachAll(for: self)
        attachedSessionIDs.removeAll()
        xpc_connection_cancel(connection)
        onInvalidate(self)
    }

    // MARK: - Wire helpers

    private func stringArray(_ message: xpc_object_t, key: String) -> [String] {
        guard let array = xpc_dictionary_get_value(message, key),
              xpc_get_type(array) == XPC_TYPE_ARRAY else { return [] }
        var values: [String] = []
        let count = min(xpc_array_get_count(array), iGhosttyProtocol.maximumCommandArgumentCount)
        for index in 0 ..< count {
            guard let value = xpc_array_get_string(array, index) else { continue }
            values.append(String(cString: value))
        }
        return values
    }

    private func stringDictionary(_ message: xpc_object_t, key: String) -> [String: String] {
        guard let dictionary = xpc_dictionary_get_value(message, key),
              xpc_get_type(dictionary) == XPC_TYPE_DICTIONARY else { return [:] }
        var values: [String: String] = [:]
        xpc_dictionary_apply(dictionary) { entryKey, entryValue in
            if xpc_get_type(entryValue) == XPC_TYPE_STRING,
               let string = xpc_string_get_string_ptr(entryValue) {
                values[String(cString: entryKey)] = String(cString: string)
            }
            return true
        }
        return values
    }
}
