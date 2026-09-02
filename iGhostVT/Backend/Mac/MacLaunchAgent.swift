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
        /// quits, so the app offers to move itself to /Applications first
        /// (`moveToApplications()`).
        case needsRelocation
        /// Nothing is registered: either this is a first launch that has not
        /// got there yet, or the helper was turned off in Settings.
        case notRegistered
        /// Registered, but a person still has to allow it in Login Items.
        case needsApproval
        case enabled
        /// The bundle has no helper plist to register. A packaging fault —
        /// or a copy someone took apart — that no control in the app can
        /// mend; the only way on is a fresh download.
        case brokenInstallation
        case failed(String)
    }

    @Published private(set) var status: Status

    /// Where a whole copy of the app comes from, for the broken-install card.
    static let downloadPageURL = URL(string: "https://github.com/OwnGoalStudio/GhostVT/releases")!

    /// Whether sessions may be opened. `unsupported` counts: it means this
    /// type has no opinion, not that the daemon is missing.
    var isReady: Bool {
        switch status {
        case .notApplicable, .unsupported, .enabled: true
        case .needsRelocation, .notRegistered, .needsApproval, .brokenInstallation, .failed: false
        }
    }

    private init() {
        #if targetEnvironment(macCatalyst)
            status = .unsupported
            refresh()
            // Every launch registers: the plain register is idempotent and
            // bootstraps the job when launchd has none, and `activate()` is
            // where a replaced helper is caught (see `helperDigest`) — the
            // case where Login Items still says "enabled" but nothing can
            // run. Someone who turned the item off in System Settings keeps
            // it off; a register does not override that.
            if status == .enabled || status == .notRegistered {
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
                // Apple's name is broader than a missing file: after
                // `launchctl bootout` of an SMAppService job — what the zip
                // update does, and what a replaced-bundle repair does — BTM
                // has no item and this is the status that comes back even
                // though the plist is still in the bundle. Treat that as
                // unregistered so `activate()` runs. Only a bundle that
                // actually has no helper is a packaging fault.
                status = Self.bundledHelperIsPresent ? .notRegistered : .brokenInstallation
            @unknown default:
                status = .needsApproval
            }
        }

        /// Registers the bundled agent. Called on every launch, and from the
        /// cards that name a helper that is not running.
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

        /// Opens System Settings on Login Items, for the approval step.
        func openLoginItemsSettings() {
            guard #available(macCatalyst 16.0, *) else { return }
            SMAppService.openSystemSettingsLoginItems()
        }

        /// Moves this bundle into the Applications folder and reopens it from
        /// there — what LetsMove does for AppKit apps, possible here because
        /// the Mac build is not sandboxed.
        ///
        /// The bundle that moves is the *original*: a quarantined download
        /// runs from Gatekeeper's read-only translocation mount, and
        /// `Bundle.main` names the mount, not the file in Downloads. A move
        /// (a rename on the same volume) is tried first and a copy stands in
        /// when the source is read-only, a mounted disk image say. The
        /// quarantine flag comes off the result, or the copy would be
        /// translocated again on its first launch and land right back here.
        /// The relaunch goes through LaunchServices — `NSWorkspace`, reached
        /// through the runtime — with `createsNewApplicationInstance`, since
        /// a plain open would only activate this instance; this one exits
        /// once the new one is on its way. Nothing was connected yet (the
        /// status gates every session), so nothing is lost.
        func moveToApplications() {
            let source = Self.originalBundleURL
            let folder = Self.applicationsFolder
            let destination = folder.appendingPathComponent(source.lastPathComponent)
            let fileManager = FileManager.default
            // A bundle a shell `mv` put in Applications keeps the quarantine's
            // translocate bit, so it still runs from the mount and reads as
            // relocatable while the original already sits at the destination.
            // Trashing "what is there" would then delete the app itself; the
            // quarantine flag is all that needs to go.
            if source.resolvingSymlinksInPath().path == destination.resolvingSymlinksInPath().path {
                Self.removeQuarantine(at: source)
                Self.relaunch(from: source)
                return
            }
            do {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.trashItem(at: destination, resultingItemURL: nil)
                }
                do {
                    try fileManager.moveItem(at: source, to: destination)
                } catch {
                    try fileManager.copyItem(at: source, to: destination)
                    try? fileManager.trashItem(at: source, resultingItemURL: nil)
                }
                Self.removeQuarantine(at: destination)
            } catch {
                status = .failed(
                    String(
                        localized: "Unable to move iGhostVT to Applications. Move it there in Finder, then open it again.",
                        comment: "Mac agent error when moving the app bundle fails"
                    )
                )
                return
            }
            Self.relaunch(from: destination)
        }

        /// The folder the app belongs in: `/Applications`, or the user's own
        /// when the system one is not writable (a managed Mac).
        private static var applicationsFolder: URL {
            let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
            if FileManager.default.isWritableFile(atPath: system.path) {
                return system
            }
            let home = homeDirectory ?? NSHomeDirectory()
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent("Applications", isDirectory: true)
        }

        /// The bundle on disk, seen through Gatekeeper's translocation when
        /// there is one. `SecTranslocateCreateOriginalPathForURL` is not in
        /// the Catalyst SDK, so it is looked up in Security by hand.
        private static var originalBundleURL: URL {
            let bundle = Bundle.main.bundleURL
            typealias Original = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
            guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
                  let symbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL")
            else { return bundle }
            let original = unsafeBitCast(symbol, to: Original.self)
            guard let url = original(bundle as CFURL, nil)?.takeRetainedValue() else { return bundle }
            return url as URL
        }

        private static func removeQuarantine(at url: URL) {
            let name = "com.apple.quarantine"
            removexattr(url.path, name, XATTR_NOFOLLOW)
            guard let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { return }
            for case let item as URL in items {
                removexattr(item.path, name, XATTR_NOFOLLOW)
            }
        }

        /// The relocation alert's other answer. Through AppKit, so
        /// `applicationWillTerminate` runs as it would for ⌘Q.
        func quit() {
            AppTermination.terminate()
        }

        private static func relaunch(from url: URL) {
            guard let workspaceClass = NSClassFromString("NSWorkspace") as? NSObject.Type,
                  let workspace = workspaceClass.perform(NSSelectorFromString("sharedWorkspace"))?.takeUnretainedValue() as? NSObject,
                  let configurationClass = NSClassFromString("NSWorkspaceOpenConfiguration") as? NSObject.Type,
                  let configuration = configurationClass.perform(NSSelectorFromString("configuration"))?.takeUnretainedValue() as? NSObject
            else { return }
            configuration.setValue(true, forKey: "createsNewApplicationInstance")
            let selector = NSSelectorFromString("openApplicationAtURL:configuration:completionHandler:")
            guard workspace.responds(to: selector) else { return }
            typealias Open = @convention(c) (AnyObject, Selector, NSURL, AnyObject, AnyObject?) -> Void
            let open = unsafeBitCast(workspace.method(for: selector), to: Open.self)
            let completion: @convention(block) (AnyObject?, AnyObject?) -> Void = { _, _ in
                DispatchQueue.main.async { exit(0) }
            }
            open(workspace, selector, url as NSURL, configuration, unsafeBitCast(completion, to: AnyObject.self))
            // In case LaunchServices never calls back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { exit(0) }
        }

        /// SHA-256 of the helper binary in this bundle, or nil when there is
        /// none. Content, not version: a locally cut zip can carry the same
        /// version as the one it replaces and still be a different signature.
        private static var helperDigest: String? {
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ighostvtd")
            guard let data = try? Data(contentsOf: helper, options: .mappedIfSafe) else { return nil }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        /// The files `SMAppService.agent(plistName:)` and `BundleProgram` need.
        /// `.notFound` is not this check — see `refresh()`.
        private static var bundledHelperIsPresent: Bool {
            let root = Bundle.main.bundleURL
            let plist = root.appendingPathComponent("Contents/Library/LaunchAgents/\(plistName)")
            return FileManager.default.isReadableFile(atPath: plist.path) && helperDigest != nil
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
                            localized: "Unable to turn on Terminal Helper. Try again.",
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
            if path.hasPrefix("/Applications/") {
                return true
            }
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
        func openLoginItemsSettings() {}
        func moveToApplications() {}
        func quit() {}

    #endif
}
