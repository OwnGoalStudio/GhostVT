import Darwin
import os
import XPC

#if os(macOS)
    import Foundation
    import Security
#endif

/// Gate on the daemon's mach service.
///
/// The daemon spawns processes, so "who is asking" has to be settled from the
/// kernel's audit token rather than anything the caller sends. There are two
/// policies, and they never mix — a peer is judged by exactly one of them:
///
/// - **On the device** the daemon is root under a jailbreak's launchd. A peer
///   must carry the client entitlement, run as root or mobile, and *be* the
///   installed, root-owned app binary; a copied or rewritten client fails the
///   path and ownership checks.
/// - **On macOS** the daemon is a per-user LaunchAgent and the client is a Mac
///   Catalyst app, which cannot carry the client entitlement at all (AGENTS.md:
///   an iOS-family binary with an entitlement no profile granted will not
///   launch). The entitlement is replaced by a code-signing requirement — see
///   `MacPeerPolicy`. The macOS branch is accept-or-deny; it never falls
///   through to the device checks, so nothing about the device policy is
///   loosened by the existence of a Mac build.
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

    func authenticate(_ connection: xpc_connection_t) -> Int32? {
        var token = audit_token_t()
        ighostvtXPCConnectionGetAuditToken(connection, &token)
        let pid = Int32(bitPattern: token.val.5)
        let uid = token.val.1
        guard pid > 1 else {
            deny(pid, "implausible pid \(pid)")
            return nil
        }

        #if os(macOS)
            // The daemon runs as the logged-in user and spawns as that same
            // user, so a peer with a different uid gains nothing it did not
            // already have — and is not us.
            guard uid == getuid() else {
                deny(pid, "uid \(uid) is not the agent's own user")
                return nil
            }
            guard let clientPath = JailbreakRoot.executablePath(pid: pid) else {
                deny(pid, "executable path unreadable")
                return nil
            }
            guard let verdict = MacPeerPolicy.shared.judge(clientPath: clientPath, token: &token) else {
                return pid
            }
            deny(pid, verdict)
            return nil
        #else
            guard uid == 0 || uid == Self.mobileUserID else {
                deny(pid, "uid \(uid)")
                return nil
            }
            guard let clientPath = JailbreakRoot.executablePath(pid: pid) else {
                deny(pid, "executable path unreadable")
                return nil
            }
            guard hasRequiredEntitlements(token: &token) else {
                deny(pid, "missing client entitlement")
                return nil
            }

            for installedPath in installedClientPaths {
                guard isRootOwnedExecutable(installedPath) else {
                    DaemonFileLog.log("peer \(pid): candidate \(installedPath) failed the root-owned check")
                    continue
                }
                if clientPath == installedPath {
                    return pid
                }
            }
            deny(
                pid,
                "\(clientPath) is not the installed client "
                    + "(expected \(installedClientPaths.joined(separator: ", ")))"
            )
            return nil
        #endif
    }

    private func deny(_ pid: Int32, _ reason: String) {
        DaemonLog.server.error("peer \(pid) denied: \(reason, privacy: .public)")
        DaemonFileLog.log("peer \(pid) denied: \(reason)")
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

#if os(macOS)

    /// What a macOS peer has to prove, given that it cannot carry the client
    /// entitlement.
    ///
    /// The check is a real code-signing validation against the caller's audit
    /// token — `SecCodeCopyGuestWithAttributes` asks the kernel which code
    /// owns that token, so there is no pid-reuse race to lose. What the
    /// signature must then satisfy depends on how *this daemon* was signed,
    /// which is the only trustworthy statement available about the build we
    /// are part of:
    ///
    /// - **Signed with a Developer ID** (the notarizable zip): the peer must be
    ///   `wiki.qaq.iGhostVT`, anchored to Apple, from the same team. That is
    ///   unforgeable without the team's certificate, and it holds wherever the
    ///   user dragged the app.
    /// - **Ad-hoc signed** (`make mac-zip` with no identity, and every CI
    ///   build): there is no certificate to pin, so identity is established by
    ///   *location* instead — the peer must be the `iGhostVT` binary sitting
    ///   beside this daemon in the same `Contents/MacOS`. The bundled agent is
    ///   launched from inside the app bundle by `BundleProgram`, so that
    ///   sibling is definitionally the app that shipped with us, and an
    ///   attacker who can write there can replace the daemon itself. The
    ///   identifier check still runs; it just is not what is load-bearing.
    ///
    /// Both branches sit behind the uid check in the caller, so the residual
    /// threat is another process of the same user — which can already spawn
    /// shells without asking this daemon for anything.
    final class MacPeerPolicy {
        static let shared = MacPeerPolicy()

        private static let clientIdentifier = "wiki.qaq.iGhostVT"

        /// Team identifier of the daemon's own signature, `nil` when ad-hoc.
        private let teamIdentifier: String?
        /// The app binary that shipped in the same bundle as this daemon.
        private let siblingClientPath: String?
        private let requirement: SecRequirement?

        private init() {
            let team = Self.ownTeamIdentifier()
            teamIdentifier = team
            siblingClientPath = Self.ownSiblingClientPath()

            let text = if let team {
                "identifier \"\(Self.clientIdentifier)\" and anchor apple generic "
                    + "and certificate leaf[subject.OU] = \"\(team)\""
            } else {
                "identifier \"\(Self.clientIdentifier)\""
            }
            var compiled: SecRequirement?
            if SecRequirementCreateWithString(text as CFString, [], &compiled) != errSecSuccess {
                DaemonFileLog.log("mac peer policy: could not compile requirement '\(text)'")
                compiled = nil
            }
            requirement = compiled
            DaemonFileLog.log(
                "mac peer policy: requirement '\(text)'"
                    + (team == nil ? ", sibling \(siblingClientPath ?? "unresolved")" : "")
            )
        }

        /// `nil` means the peer is accepted; a string is the denial reason.
        func judge(clientPath: String, token: inout audit_token_t) -> String? {
            #if DEBUG
                // The Mac Catalyst harness (`make mac-run`): a Debug daemon in
                // DerivedData accepts the app Xcode just built beside it. The
                // two are not bundle siblings and neither is signed by
                // anything, so the same-user check is the whole gate — which
                // off-device, where the daemon spawns as that user, is the
                // whole threat model. No Release build knows this peer.
                if clientPath.hasSuffix("/iGhostVT.app/Contents/MacOS/iGhostVT") {
                    return nil
                }
            #endif

            guard let requirement else {
                return "the code-signing requirement could not be compiled"
            }
            guard let code = Self.copyCode(token: &token) else {
                return "the kernel named no code for the caller's audit token"
            }
            let status = SecCodeCheckValidity(code, [], requirement)
            guard status == errSecSuccess else {
                return "code signature check failed (OSStatus \(status))"
            }
            guard teamIdentifier == nil else { return nil }

            guard let siblingClientPath else {
                return "this daemon is ad-hoc signed and is not inside an app bundle"
            }
            guard JailbreakRoot.canonicalPath(clientPath) == siblingClientPath else {
                return "\(clientPath) is ad-hoc signed and is not \(siblingClientPath)"
            }
            return nil
        }

        private static func copyCode(token: inout audit_token_t) -> SecCode? {
            let tokenData = withUnsafeBytes(of: token) { Data($0) } as CFData
            let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
            var code: SecCode?
            guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess else {
                return nil
            }
            return code
        }

        private static func ownTeamIdentifier() -> String? {
            var code: SecCode?
            guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
            var staticCode: SecStaticCode?
            guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
                  let staticCode
            else { return nil }
            var information: CFDictionary?
            guard SecCodeCopySigningInformation(
                staticCode,
                SecCSFlags(rawValue: kSecCSSigningInformation),
                &information
            ) == errSecSuccess,
                let entries = information as? [String: Any]
            else { return nil }
            return entries[kSecCodeInfoTeamIdentifier as String] as? String
        }

        /// `<bundle>/Contents/MacOS/iGhostVT`, when this daemon is itself at
        /// `<bundle>/Contents/MacOS/ighostvtd`. `nil` for the harness build,
        /// which lives in DerivedData beside nothing.
        private static func ownSiblingClientPath() -> String? {
            guard let own = JailbreakRoot.currentExecutablePath() else { return nil }
            let directory = (own as NSString).deletingLastPathComponent
            guard directory.hasSuffix("/Contents/MacOS") else { return nil }
            return JailbreakRoot.canonicalPath(directory + "/iGhostVT")
        }
    }

#endif
