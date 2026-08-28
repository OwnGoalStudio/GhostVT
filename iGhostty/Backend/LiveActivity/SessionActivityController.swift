//
//  SessionActivityController.swift
//  iGhostty
//

import ActivityKit
import Foundation

/// Mirrors the open terminal tabs into one Live Activity, so the Dynamic
/// Island and the lock screen show what is running and where.
///
/// Every window registers a snapshot closure; `refresh()` walks them and
/// builds the payload. One source, so the count and the list can never
/// disagree — the count the widget shows is derived from the same sessions it
/// lists, plus the daemon sessions no window is holding (detached shells,
/// which are still alive and still worth surfacing).
///
/// Anything that moves a tab — new tab, close, connect, retitle, a directory
/// change — calls `refresh()`. No-op below iOS 16.2 or when the user disabled
/// activities.
@MainActor
final class SessionActivityController {
    static let shared = SessionActivityController()

    /// What a window reports about itself. Nil once its TabManager is gone.
    struct WindowSnapshot {
        var tabs: [TerminalTab]
        var activeTabID: UUID?
    }

    /// How many sessions the payload carries. ActivityKit budgets the state
    /// tightly and neither presentation shows more than four.
    private static let listLimit = 4

    /// One weak entry per window, pruned as scenes go away.
    private var windows: [ObjectIdentifier: () -> WindowSnapshot?] = [:]

    private init() {}

    func register(_ key: AnyObject, snapshot: @escaping () -> WindowSnapshot?) {
        windows[ObjectIdentifier(key)] = snapshot
        refresh()
    }

    func refresh() {
        // Live Activities do not exist on the Mac; the Catalyst development
        // build keeps the callers and drops the payload here.
        #if !targetEnvironment(macCatalyst)
            guard #available(iOS 16.2, *) else { return }
            let state = currentState()
            Task { await Self.apply(state) }
        #endif
    }

    @available(iOS 16.2, *)
    private func currentState() -> TerminalSessionAttributes.ContentState {
        var sessions: [TerminalSessionAttributes.Session] = []
        var attachedIDs: Set<UInt64> = []

        for (key, snapshot) in windows {
            guard let window = snapshot() else {
                windows.removeValue(forKey: key)
                continue
            }
            for tab in window.tabs {
                let number = (tab.store.activeTransport as? XPCDaemonTransport)?
                    .currentSessionID
                if let number {
                    attachedIDs.insert(number)
                }
                sessions.append(
                    TerminalSessionAttributes.Session(
                        id: tab.id.uuidString,
                        title: tab.reportedTitle,
                        directory: Self.displayPath(tab.terminal.workingDirectory),
                        shell: Self.configuredShellName,
                        number: number,
                        status: Self.status(for: tab.store.status),
                        isActive: tab.id == window.activeTabID
                    )
                )
            }
        }

        // Sessions the daemon holds that no tab here is attached to are
        // running detached. The directory is a cache of the daemon's own
        // registry — the one source that actually knows.
        let detached = DaemonSessionDirectory.shared.sessions
            .filter { !attachedIDs.contains($0.id) }
            .count
        return TerminalSessionAttributes.ContentState(
            sessions: Array(sessions.prefix(Self.listLimit)),
            overflowCount: max(0, sessions.count - Self.listLimit),
            detachedCount: detached
        )
    }

    private static var configuredShellName: String {
        guard let path = UserDefaults.standard.string(forKey: "Shell.path"),
              !path.isEmpty
        else { return "" }
        return (path as NSString).lastPathComponent
    }

    @available(iOS 16.2, *)
    private static func status(
        for status: TerminalSessionStore.Status
    ) -> TerminalSessionAttributes.Session.Status {
        switch status {
        case .idle, .connecting: return .starting
        case .connected: return .live
        case .failed: return .failed
        }
    }

    /// OSC 7 arrives as a `file://` URL from some shells and a bare path from
    /// others; either way the shell's home is noise, so it collapses to `~`.
    private static func displayPath(_ reported: String?) -> String {
        guard var path = reported, !path.isEmpty else { return "" }
        if path.hasPrefix("file://"), let url = URL(string: path) {
            path = url.path
        }
        for home in ["/private/var/mobile", "/var/mobile"] where path.hasPrefix(home) {
            return path == home ? "~" : "~" + path.dropFirst(home.count)
        }
        return path
    }

    #if !targetEnvironment(macCatalyst)
        @available(iOS 16.2, *)
        private static func apply(_ state: TerminalSessionAttributes.ContentState) async {
            let existing = Activity<TerminalSessionAttributes>.activities

            guard state.totalCount > 0 else {
                for activity in existing {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
                return
            }

            let content = ActivityContent(state: state, staleDate: nil)
            if let activity = existing.first {
                await activity.update(content)
                return
            }
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            _ = try? Activity.request(
                attributes: TerminalSessionAttributes(),
                content: content
            )
        }
    #endif
}
