//
//  MacLaunchAgent.swift
//  iGhostVT
//

import Combine
import CryptoKit
import Foundation

#if targetEnvironment(macCatalyst)
    import ServiceManagement
#endif

/// The distributed Mac build's half of the daemon boundary.
///
/// On the device `ighostvtd` is a LaunchDaemon the .deb installed and the app
/// only ever connects to it. On macOS there is no package manager, so the
/// helper ships *inside* the app bundle — `Contents/MacOS/ighostvtd`, launched
/// by `Contents/Library/LaunchAgents/wiki.qaq.ighostvtd.plist` — and the app
/// registers it with `SMAppService` on first launch. The user approves it once
/// in Login Items, and from then on the agent moves, updates, and is deleted
/// with the app.
///
/// This type exists on every platform so call sites need no `#if`. Off
/// Catalyst it reports `.notApplicable`, which reads as "nothing to gate on".
@MainActor
final class MacLaunchAgent: ObservableObject {
    static let shared = MacLaunchAgent()

    enum Status: Equatable {
        /// iOS and iPadOS: the .deb installed the daemon, there is nothing to
        /// register.
        case notApplicable
        /// macOS 12, where `SMAppService` does not exist. Nothing to offer;
        /// treated as ready so the ordinary connection error still surfaces
        /// rather than being masked by a control that cannot help.
        case unsupported
        /// Launched from the download, or Gatekeeper-translocated. Registering
        /// now would bind Login Items to a path that vanishes when the app
        /// quits, so the app asks to be moved to /Applications first.
        case needsRelocation
        /// Nothing is registered: either this is a first launch that has not
        /// got there yet, or the helper was turned off in Settings.
        case notRegistered
        /// Registered, but a person still has to allow it in Login Items.
        case needsApproval
        case enabled
        case failed(String)
    }

    @Published private(set) var status: Status

    /// Whether sessions may be opened. `unsupported` counts: it means this
    /// type has no opinion, not that the daemon is missing.
    var isReady: Bool {
        switch status {
        case .notApplicable, .unsupported, .enabled: true
        case .needsRelocation, .notRegistered, .needsApproval, .failed: false
        }
    }

    /// Whether the user can be offered a Turn Off control — only worth showing
    /// once there is something registered to turn off.
    var isRegistered: Bool {
        status == .enabled || status == .needsApproval
    }

    private init() {
        #if targetEnvironment(macCatalyst)
            status = .unsupported
            refresh()
            // First launch registers by itself; a later one does not, because
            // by then `notRegistered` may be a decision somebody made. An
            // *enabled* helper goes through `activate()` every launch: the
            // plain register is idempotent and bootstraps the job when launchd
            // has none, and `activate()` is where a replaced helper is caught
            // (see `helperDigest`) — the case where Login Items still says
            // "enabled" but nothing can run.
            if status == .enabled || (status == .notRegistered && !Self.isTurnedOffByUser) {
                activate()
            }
        #else
            status = .notApplicable
        #endif
    }

    #if targetEnvironment(macCatalyst)

        /// Must match the file `Scripts/package-mac.sh` stages into
        /// `Contents/Library/LaunchAgents`.
        private static let plistName = "wiki.qaq.ighostvtd.plist"

        /// Re-reads the agent's state. Observes only — it never registers, so
        /// it is safe to call from `sceneDidBecomeActive` (where a change made
        /// in System Settings while the app was in the background gets
        /// noticed) without undoing a person's decision to turn the helper off.
        func refresh() {
            guard #available(macCatalyst 16.0, *) else {
                status = .unsupported
                return
            }
            guard Self.isInApplications else {
                status = .needsRelocation
                return
            }
            let service = SMAppService.agent(plistName: Self.plistName)
            switch service.status {
            case .enabled:
                status = .enabled
            case .requiresApproval:
                status = .needsApproval
            case .notRegistered:
                status = .notRegistered
            case .notFound:
                // The plist is missing from the bundle. That is a packaging
                // fault, not something a person can act on, so name it as one
                // instead of sending them to Login Items.
                status = .failed(
                    String(
                        localized: "The background helper is missing. Reinstall iGhostVT.",
                        comment: "Mac agent error when the bundled LaunchAgent plist is absent"
                    )
                )
            @unknown default:
                status = .needsApproval
            }
        }

        /// Registers the bundled agent. Called on every launch while the
        /// helper is enabled, on a first launch, and from Settings after
        /// somebody turned it off.
        ///
        /// A registration is not just a plist: Background Task Management
        /// keeps a *launch constraint* for the item, and for an ad-hoc signed
        /// helper (no Team ID) that constraint pins the exact binary. After an
        /// update replaces the bundle, `register()` alone is worse than
        /// useless — BTM reuses the existing item, launchd submits the job,
        /// AMFI kills the new helper on the spot ("Launch Constraint
        /// Violation"), launchd drops the service, and BTM's own repair ten
        /// seconds later leaves a job whose program is the unresolved relative
        /// `Contents/MacOS/ighostvtd`, retried every ten seconds forever. A
        /// relaunch finds that item and changes nothing. Only unregistering
        /// discards the item, so that is what happens whenever the helper in
        /// the bundle is not the one this app registered last time.
        func activate() {
            guard #available(macCatalyst 16.0, *) else { return }
            guard Self.isInApplications else {
                status = .needsRelocation
                return
            }
            Self.isTurnedOffByUser = false
            let service = SMAppService.agent(plistName: Self.plistName)
            let digest = Self.helperDigest
            if service.status != .notRegistered, digest != Self.registeredHelperDigest {
                // An unregister that fails leaves the stale item in place and
                // the register below finds it; the status re-read there is
                // still the truth, so the error itself has nothing to add.
                try? service.unregister()
            }
            register(service, helperDigest: digest)
        }

        /// Removes the agent from Login Items.
        ///
        /// Moving the app to the Trash does *not* do this — the Login Items
        /// entry outlives the bundle and shows up as a nameless leftover — so
        /// Settings carries this control and surfaces what it returns.
        func deactivate() {
            guard #available(macCatalyst 16.0, *) else { return }
            do {
                try SMAppService.agent(plistName: Self.plistName).unregister()
                Self.isTurnedOffByUser = true
                Self.registeredHelperDigest = nil
                refresh()
            } catch {
                status = .failed(
                    String(
                        localized: "Unable to turn off the background helper. Try again.",
                        comment: "Mac agent error when unregistering the LaunchAgent fails"
                    )
                )
            }
        }

        /// Whether the helper was turned off deliberately, as opposed to never
        /// having been registered. Persisted because the difference only
        /// matters across launches: it is what stops the next one from
        /// switching the helper back on behind somebody's back.
        private static let turnedOffKey = "MacLaunchAgent.turnedOffByUser"
        private static var isTurnedOffByUser: Bool {
            get { UserDefaults.standard.bool(forKey: turnedOffKey) }
            set { UserDefaults.standard.set(newValue, forKey: turnedOffKey) }
        }

        /// Opens System Settings on Login Items, for the approval step.
        func openLoginItemsSettings() {
            guard #available(macCatalyst 16.0, *) else { return }
            SMAppService.openSystemSettingsLoginItems()
        }

        /// SHA-256 of the helper binary in this bundle, or nil when there is
        /// none. Content, not version: a locally cut zip can carry the same
        /// version as the one it replaces and still be a different signature.
        private static var helperDigest: String? {
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ighostvtd")
            guard let data = try? Data(contentsOf: helper, options: .mappedIfSafe) else { return nil }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        /// The digest of the helper the last successful `register()` was for.
        /// Absent on installs older than this check, which reads as "unknown"
        /// and re-registers once — the state an update from such a version
        /// leaves behind is exactly the one this exists to repair.
        private static let registeredHelperDigestKey = "MacLaunchAgent.registeredHelperDigest"
        private static var registeredHelperDigest: String? {
            get { UserDefaults.standard.string(forKey: registeredHelperDigestKey) }
            set { UserDefaults.standard.set(newValue, forKey: registeredHelperDigestKey) }
        }

        @available(macCatalyst 16.0, *)
        private func register(_ service: SMAppService, helperDigest: String?) {
            do {
                try service.register()
                Self.registeredHelperDigest = helperDigest
            } catch {
                // A registration that fails because approval is pending is not
                // an error worth showing; the status re-read below tells the
                // truth either way.
                if service.status != .requiresApproval, service.status != .enabled {
                    status = .failed(
                        String(
                            localized: "Unable to turn on the background helper. Try again.",
                            comment: "Mac agent error when registering the LaunchAgent fails"
                        )
                    )
                    return
                }
            }
            switch service.status {
            case .enabled: status = .enabled
            default: status = .needsApproval
            }
        }

        /// Login Items binds to the path the app was registered from. From a
        /// download that path is either inside the quarantine's read-only
        /// translocation mount or a folder the user will empty, and either way
        /// the entry is dangling by the second launch — so registration waits
        /// until the app lives somewhere permanent.
        private static var isInApplications: Bool {
            let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
            if path.hasPrefix("/Applications/") { return true }
            guard let home = Self.homeDirectory else { return false }
            return path.hasPrefix("\(home)/Applications/")
        }

        /// The real home directory. Not `homeDirectoryForCurrentUser`, which
        /// Catalyst marks unavailable, and not `NSHomeDirectory()`, which
        /// answers the app's container when sandboxed — this build is not, but
        /// a path check has no business depending on that staying true.
        private static var homeDirectory: String? {
            guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else {
                return nil
            }
            return URL(fileURLWithPath: String(cString: directory))
                .resolvingSymlinksInPath().path
        }

    #else

        func refresh() {}
        func activate() {}
        func deactivate() {}
        func openLoginItemsSettings() {}

    #endif
}
