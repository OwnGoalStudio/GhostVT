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
        iGhosttyProtocol.clientEntitlement,
    ]

    private lazy var installedClientPaths = resolveInstalledClientPaths()

    /// The Mac Catalyst harness: a Debug daemon built for macOS accepts the
    /// app Xcode just built, running as the daemon's own user. Release
    /// builds and every device build know no such peer — there the accepted
    /// peers are root and mobile alone.
    #if os(macOS) && DEBUG
        private static let developmentUserID = getuid()
        private static let developmentClientSuffix = "/iGhostty.app/Contents/MacOS/iGhostty"

        private static func isDevelopmentPeer(uid: UInt32, clientPath: String) -> Bool {
            uid == developmentUserID && clientPath.hasSuffix(developmentClientSuffix)
        }
    #else
        private static let developmentUserID: UInt32? = nil

        private static func isDevelopmentPeer(uid _: UInt32, clientPath _: String) -> Bool {
            false
        }
    #endif

    func authenticate(_ connection: xpc_connection_t) -> Int32? {
        var token = audit_token_t()
        ighosttyXPCConnectionGetAuditToken(connection, &token)
        let pid = Int32(bitPattern: token.val.5)
        let uid = token.val.1
        guard pid > 1 else {
            DaemonLog.server.error("peer denied: implausible pid \(pid)")
            DaemonFileLog.log("peer denied: implausible pid \(pid)")
            return nil
        }
        guard uid == 0 || uid == Self.mobileUserID || uid == Self.developmentUserID else {
            DaemonLog.server.error("peer \(pid) denied: uid \(uid)")
            DaemonFileLog.log("peer \(pid) denied: uid \(uid)")
            return nil
        }
        guard let clientPath = JailbreakRoot.executablePath(pid: pid) else {
            DaemonLog.server.error("peer \(pid) denied: executable path unreadable")
            DaemonFileLog.log("peer \(pid) denied: executable path unreadable")
            return nil
        }

        // The Mac Catalyst development build: the daemon is a per-user
        // LaunchAgent and the app is whatever Xcode just built, so there is
        // no installed, root-owned path to insist on — and no client
        // entitlement either: a Catalyst app is an iOS-family binary, and
        // macOS refuses to launch one carrying an entitlement no provisioning
        // profile granted (RunningBoard's "Launchd job spawn failed"), ad-hoc
        // signature or not. What remains is the peer being the daemon's own
        // user and its executable living in an iGhostty.app bundle. Off the
        // device that is the whole threat model: the daemon runs as that
        // user and spawns as that user. Debug macOS builds only.
        if Self.isDevelopmentPeer(uid: uid, clientPath: clientPath) {
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
        iGhosttyProtocol.clientPaths.compactMap {
            JailbreakRoot.canonicalPath(JailbreakRoot.resolve(JailbreakRoot.bootstrapPath($0)))
        }
    }

    private func hasRequiredEntitlements(token: inout audit_token_t) -> Bool {
        Self.requiredEntitlements.allSatisfy { entitlement in
            let value = entitlement.withCString {
                ighosttyXPCCopyEntitlement($0, &token)
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
