import Darwin
import Dispatch
import Foundation
import os
import XPC

/// Mach service listener.
///
/// Accepts several peers at once (an iPad can have more than one app window)
/// and never exits on its own initiative. It used to idle-exit after thirty
/// seconds with no peers and no sessions, leaving launchd to demand-launch it
/// again.
///
/// Demand launch does work — killing the daemon and reopening the app brings
/// it back through `ipc (mach)`, verified on device. Exiting on the daemon's
/// own judgement is still wrong. The check and the exit cannot be made atomic
/// against launchd routing a new connection, so a client that arrives in that
/// window watches the service disappear instead of getting a session, and it
/// is exactly the window the app is most likely to be in: the last shell
/// exiting is what empties the registry, and reaching for a new tab is what
/// the user does next. Staying resident costs a few MB and removes the whole
/// class of failure. launchd's `KeepAlive` covers what remains, which is a
/// crash.
///
/// The one exit is the one a client asks for (`shutdown`, answered in
/// `PeerSession`): the quitting app, once it has closed its tabs and seen
/// the registry empty. Nobody is reaching for a tab then. Whether the exit
/// sticks is the plist's business — the Mac agent's `KeepAlive` restarts only
/// an unsuccessful exit and the mach service demand-launches it when the app
/// returns; the device daemon is kept alive unconditionally and would come
/// straight back, so the app never asks there.
final class DaemonServer {
    private let controlQueue = DispatchQueue(
        label: "wiki.qaq.ighostvt.daemon.control",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem
    )
    private let authenticator = PeerAuthenticator()
    private lazy var registry = SessionRegistry(queue: controlQueue)

    private var listener: xpc_connection_t?
    private var peers: [ObjectIdentifier: PeerSession] = [:]

    func start() throws {
        guard listener == nil else { return }
        guard let listener = iGhostVTProtocol.serviceName.withCString({
            ighostvtCreateMachServiceListener(
                $0,
                controlQueue,
                PrivateSystemConstant.machServiceListener
            )
        }) else {
            throw iGhostVTDaemonError.transportFailure
        }
        self.listener = listener

        xpc_connection_set_event_handler(listener) { [weak self] event in
            autoreleasepool {
                self?.accept(event)
            }
        }
        xpc_connection_activate(listener)
        DaemonLog.server.info(
            "listening on \(iGhostVTProtocol.serviceName, privacy: .public), pid \(getpid())"
        )
        DaemonFileLog.log(
            "listening on \(iGhostVTProtocol.serviceName), uid \(getuid()) euid \(geteuid())"
        )
    }

    private func accept(_ event: xpc_object_t) {
        guard xpc_get_type(event) == XPC_TYPE_CONNECTION else { return }
        guard let clientPID = authenticator.authenticate(event) else {
            DaemonFileLog.log("peer rejected, connection canceled")
            xpc_connection_cancel(event)
            return
        }

        let peer = PeerSession(
            connection: event,
            clientPID: clientPID,
            queue: controlQueue,
            registry: registry
        ) { [weak self] peer in
            self?.peerInvalidated(peer)
        }
        peers[ObjectIdentifier(peer)] = peer
        peer.activate()
        DaemonLog.server.info("peer \(clientPID) connected, \(self.peers.count) peer(s)")
        DaemonFileLog.log("peer \(clientPID) connected, \(peers.count) peer(s)")
    }

    /// The peer went away. Its sessions stay: detaching is not closing, and
    /// the next launch reattaches to them.
    private func peerInvalidated(_ peer: PeerSession) {
        peers.removeValue(forKey: ObjectIdentifier(peer))
        DaemonLog.server.info("peer gone, \(self.peers.count) peer(s) remain")
        DaemonFileLog.log("peer gone, \(peers.count) peer(s) remain")
    }
}
