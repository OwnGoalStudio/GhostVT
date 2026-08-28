import Darwin
import os
import XPC

/// Gate on the daemon's mach service.
///
/// The daemon spawns processes as root, so "who is asking" has to be settled
/// from the kernel's audit token rather than anything the caller sends. A peer
/// must carry the client entitlement, run as root or mobile, and *be* the
/// installed, root-owned app binary — a copied or rewritten client fails the
/// path and ownership checks.
final class PeerAuthenticator {
    private static let mobileUserID: UInt32 = 501
    /// `platform-application` used to be required here too. It was never
    /// load-bearing: it attests that a binary is signed as part of the
    /// platform, not that it is *this* client, which is what the path and
    /// ownership checks below establish. Requiring it forced the app to
    /// carry an entitlement that tightens the app's own sandbox and buys
    /// this side nothing, so the app dropped it and so did this list.
    private static let requiredEntitlements = [
        iGhostVTProtocol.clientEntitlement,
    ]

    private lazy var installedClientPaths = resolveInstalledClientPaths()

    /// The Mac Catalyst harness: a Debug daemon built for macOS accepts the
    /// app Xcode just built, running as the daemon's own user and carrying
    /// no entitlement (AGENTS.md: a Catalyst app cannot carry one). Off the
    /// device that is the whole threat model — the daemon runs and spawns
    /// as that user. Release and device builds know no such peer.
    #if os(macOS) && DEBUG
        private static let developmentPeer: (uid: UInt32, bundleSuffix: String)? =
            (getuid(), "/iGhostVT.app/Contents/MacOS/iGhostVT")
    #else
        private static let developmentPeer: (uid: UInt32, bundleSuffix: String)? = nil
    #endif

    func authenticate(_ connection: xpc_connection_t) -> Int32? {
        var token = audit_token_t()
        ighostvtXPCConnectionGetAuditToken(connection, &token)
        let pid = Int32(bitPattern: token.val.5)
        let uid = token.val.1
        guard pid > 1 else {
            DaemonLog.server.error("peer denied: implausible pid \(pid)")
            DaemonFileLog.log("peer denied: implausible pid \(pid)")
            return nil
        }
        guard uid == 0 || uid == Self.mobileUserID || uid == Self.developmentPeer?.uid else {
            DaemonLog.server.error("peer \(pid) denied: uid \(uid)")
            DaemonFileLog.log("peer \(pid) denied: uid \(uid)")
            return nil
        }
        guard let clientPath = JailbreakRoot.executablePath(pid: pid) else {
            DaemonLog.server.error("peer \(pid) denied: executable path unreadable")
            DaemonFileLog.log("peer \(pid) denied: executable path unreadable")
            return nil
        }

        if let peer = Self.developmentPeer, uid == peer.uid, clientPath.hasSuffix(peer.bundleSuffix) {
            return pid
        }

        guard hasRequiredEntitlements(token: &token) else {
            DaemonLog.server.error("peer \(pid) denied: missing client entitlement")
            DaemonFileLog.log("peer \(pid) denied: missing client entitlement")
            return nil
        }

        for installedPath in installedClientPaths {
            guard isRootOwnedExecutable(installedPath) else {
                DaemonFileLog.log("peer \(pid): candidate \(installedPath) failed the root-owned check")
                continue
            }
            if clientPath == installedPath { return pid }
        }
        DaemonLog.server.error(
            "peer \(pid) denied: \(clientPath, privacy: .public) is not the installed client (expected \(self.installedClientPaths.joined(separator: ", "), privacy: .public))"
        )
        DaemonFileLog.log(
            "peer \(pid) denied: \(clientPath) is not the installed client (expected \(installedClientPaths.joined(separator: ", ")))"
        )
        return nil
    }

    /// The app installs under the same bootstrap root as the daemon, so the
    /// permitted client paths are written relative to that root and mapped
    /// through the layout the daemon recovered from its own location.
    private func resolveInstalledClientPaths() -> [String] {
        iGhostVTProtocol.clientPaths.compactMap {
            JailbreakRoot.canonicalPath(JailbreakRoot.resolve(JailbreakRoot.bootstrapPath($0)))
        }
    }

    private func hasRequiredEntitlements(token: inout audit_token_t) -> Bool {
        Self.requiredEntitlements.allSatisfy { entitlement in
            let value = entitlement.withCString {
                ighostvtXPCCopyEntitlement($0, &token)
            }
            return value.map {
                xpc_get_type($0) == XPC_TYPE_BOOL && xpc_bool_get_value($0)
            } ?? false
        }
    }

    private func isRootOwnedExecutable(_ path: String) -> Bool {
        var metadata = stat()
        guard stat(path, &metadata) == 0 else { return false }
        return metadata.st_uid == 0
            && metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && metadata.st_mode & mode_t(S_IXUSR) != 0
            && metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
    }
}
