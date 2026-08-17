//
//  TerminalTab.swift
//  iGhostty
//

import Combine
import Foundation
import GhosttyTerminal

/// One terminal session: its own surface state and its own connection.
/// Tabs stay alive (and connected) while in the background; only the active
/// tab's surface is visible.
///
/// The connection is a daemon session that outlives the app: closing the tab
/// kills the shell (`closeSession`), while scene teardown only detaches
/// (`disconnect`) and the ledger remembers the session ID so a cold launch
/// can reattach.
@MainActor
final class TerminalTab: ObservableObject, Identifiable {
    let id = UUID()
    let terminal: TerminalViewState
    let store: TerminalSessionStore

    /// Mutable so a reconnect after an in-app detach reattaches to the same
    /// shell instead of spawning a fresh one. Shared with the transport
    /// factory, which reads it at every connect.
    private let daemonSession: DaemonSessionBox
    private var statusObservation: AnyCancellable?
    private var activityObservation: AnyCancellable?

    init(resumeDaemonSessionID: UInt64? = nil) {
        let daemonSession = DaemonSessionBox(id: resumeDaemonSessionID)
        self.daemonSession = daemonSession
        terminal = TerminalViewState(theme: AppTheme.shared.terminalTheme)
        store = TerminalSessionStore(makeTransport: {
            let transport = XPCDaemonTransport(
                shellPath: UserDefaults.standard.string(forKey: "Shell.path"),
                resumeSessionID: daemonSession.id
            )
            // A real process exit (including one we asked for via
            // closeSession) means the ID must never be reused: forget it in
            // the box so the next connect opens a fresh shell instead of
            // attempting a doomed reattach. The daemon's own registry is the
            // only session record; just tell the directory to re-read it.
            transport.onSessionExit = { id, _ in
                daemonSession.clear(ifMatches: id)
                Task { @MainActor in
                    DaemonSessionDirectory.shared.refresh()
                }
            }
            return transport
        })
        terminal.configuration = TerminalSurfaceOptions(
            backend: .inMemory(store.session)
        )
        // The user's arrangement of the keyboard accessory bar; later edits
        // reach existing tabs through RootView's store subscription.
        terminal.inputAccessoryItems = KeyboardBarStore.shared.accessoryItems
        TerminalSessionStore.logger.info(
            "tab created, resume id \(resumeDaemonSessionID.map(String.init) ?? "none"); waiting for the surface's first viewport"
        )
        statusObservation = store.$status.sink { [weak self] status in
            guard status == .connected else { return }
            Task { @MainActor [weak self] in
                self?.recordDaemonSessionID()
            }
        }
        // The Live Activity payload carries title, working directory, and
        // connection status; shells retitle and re-report OSC 7 on every
        // prompt, so dedupe each stream and debounce the merge before
        // spending ActivityKit update budget.
        activityObservation = Publishers.Merge3(
            terminal.$title.removeDuplicates().map { _ in () },
            terminal.$workingDirectory.removeDuplicates().map { _ in () },
            store.$status.removeDuplicates().map { _ in () }
        )
        .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
        .sink { _ in
            Task { @MainActor in
                SessionActivityController.shared.refresh()
            }
        }
    }

    var displayTitle: String {
        terminal.title.isEmpty ? store.endpointDescription : terminal.title
    }

    /// Whether closing this tab would kill a real shell — the case the
    /// interface confirms first, because `close()` has no undo. The box ID is
    /// the authoritative half: a tab detached in the background is not
    /// `.connected`, but its shell is alive in the daemon, and that silent
    /// kill is the one that hurts most. A tab that never got a session has
    /// nothing to lose.
    var hasLiveSession: Bool {
        daemonSession.id != nil || store.status == .connected
    }

    /// Viewport text for the tab-switcher card preview.
    func snapshotPreview() -> String {
        store.session.readViewportText() ?? ""
    }

    /// The user closed the tab: the shell dies with it.
    ///
    /// The kill must reach the daemon even when the transport has no live
    /// link (failed connect, detached, daemon restart) — otherwise the
    /// shell runs forever against the daemon's session ceiling with its
    /// ledger entry already gone, so nothing could ever kill it.
    func close() {
        if let transport = store.activeTransport as? XPCDaemonTransport,
           transport.currentSessionID != nil {
            transport.closeSession()
        } else if let id = daemonSession.id {
            XPCDaemonTransport.killSession(id)
        }
        store.disconnect()
        DaemonSessionDirectory.shared.refresh()
    }

    /// The window is going away but the shell should live on in the daemon;
    /// the ledger already holds the session ID for the next launch.
    func detach() {
        store.disconnect()
    }

    private func recordDaemonSessionID() {
        guard
            let transport = store.activeTransport as? XPCDaemonTransport,
            let id = transport.currentSessionID
        else { return }
        daemonSession.id = id
        DaemonSessionDirectory.shared.refresh()
    }
}

/// Reference cell shared between the tab, its transport factory, and the
/// transport's exit callback (which fires on the transport queue).
final class DaemonSessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _id: UInt64?

    init(id: UInt64?) {
        _id = id
    }

    var id: UInt64? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _id
        }
        set {
            lock.lock()
            _id = newValue
            lock.unlock()
        }
    }

    func clear(ifMatches id: UInt64) {
        lock.lock()
        if _id == id {
            _id = nil
        }
        lock.unlock()
    }
}
