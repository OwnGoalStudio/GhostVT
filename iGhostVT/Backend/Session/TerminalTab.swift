//
//  TerminalTab.swift
//  iGhostVT
//

import Combine
import Foundation
import GhosttyTerminal
import SwiftUI

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

    /// Interaction lock: the surface's view refuses touches and keyboard
    /// focus (`LockableTerminalView`) while the session keeps running,
    /// output keeps flowing, and the surface keeps rendering. The tab's
    /// context menu is the way in and out.
    @Published var isLocked = false {
        didSet {
            (terminal.attachedPlatformView as? LockableTerminalView)?
                .isInteractionLocked = isLocked
        }
    }

    /// Keyboard lock: the software keyboard stays down whatever asks for it
    /// (`LockableTerminalView.isSoftwareKeyboardLocked`); touches, scrolling,
    /// selection, and hardware keys still work.
    @Published var isKeyboardLocked = false {
        didSet {
            (terminal.attachedPlatformView as? LockableTerminalView)?
                .isSoftwareKeyboardLocked = isKeyboardLocked
        }
    }

    /// Mutable so a reconnect after an in-app detach reattaches to the same
    /// shell instead of spawning a fresh one. Shared with the transport
    /// factory, which reads it at every connect.
    private let daemonSession: DaemonSessionBox
    private var statusObservation: AnyCancellable?
    private var activityObservation: AnyCancellable?
    private var titleObservation: AnyCancellable?

    init(resumeDaemonSessionID: UInt64? = nil) {
        let daemonSession = DaemonSessionBox(id: resumeDaemonSessionID)
        self.daemonSession = daemonSession
        terminal = TerminalViewState(theme: AppTheme.shared.terminalTheme)
        // Built before the store exists (the factory closure cannot capture
        // `self` mid-init), armed right after: the exit the transport
        // observes must reach the store that presents it.
        let exitRelay = ProcessExitRelay()
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
            transport.onSessionExit = { id, status in
                daemonSession.clear(ifMatches: id)
                exitRelay.fire(status)
                Task { @MainActor in
                    DaemonSessionDirectory.shared.refresh()
                }
            }
            return transport
        })
        exitRelay.handler = { [weak self] status in
            Task { @MainActor [weak self] in
                self?.store.noteProcessExit(status: status)
            }
        }
        terminal.configuration = TerminalSurfaceOptions(
            backend: .inMemory(store.session)
        )
        // The user's arrangement of the keyboard accessory bar; later edits
        // reach existing tabs through RootView's store subscription.
        KeyboardBarStore.shared.apply(to: terminal)
        TerminalSessionStore.logger.info(
            "tab created, resume id \(resumeDaemonSessionID.map(String.init) ?? "none"); waiting for the surface's first viewport"
        )
        // `displayTitle` reads two other observable objects, and SwiftUI
        // only watches the one a view holds — the tab. Without this the
        // title capsule, the tab strip, and the sidebar keep rendering the
        // title the surface had when the view was first built. Published
        // inside an animation so a retitle — which changes a chip's width,
        // and so every chip after it — moves instead of jumping, in every
        // view at once.
        titleObservation = Publishers.Merge3(
            terminal.$title.removeDuplicates().map { _ in () },
            store.$inferredTitle.removeDuplicates().map { _ in () },
            store.$processName.removeDuplicates().map { _ in () }
        )
        .sink { [weak self] in
            withAnimation(DS.Motion.smooth) {
                self?.objectWillChange.send()
            }
        }
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
        activityObservation = Publishers.Merge4(
            terminal.$title.removeDuplicates().map { _ in () },
            store.$inferredTitle.removeDuplicates().map { _ in () },
            terminal.$workingDirectory.removeDuplicates().map { _ in () },
            store.$status.removeDuplicates().map { _ in () }
        )
        .merge(with: store.$processName.removeDuplicates().map { _ in () })
        .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
        .sink { _ in
            Task { @MainActor in
                SessionActivityController.shared.refresh()
            }
        }
        // The app's view subclass carries the interaction-lock policy; the
        // package only provides the seam. Set last, so the closure can read
        // the tab: a view is made whenever the surface mounts — a background
        // tab appearing, SwiftUI rebuilding the representable — and one born
        // after the user locked the tab must come up locked, or the lock
        // lapses the first time the view is rebuilt.
        terminal.makePlatformView = { [weak self] in
            let view = LockableTerminalView(frame: .zero)
            view.isInteractionLocked = self?.isLocked ?? false
            view.isSoftwareKeyboardLocked = self?.isKeyboardLocked ?? false
            return view
        }
    }

    /// What the tab calls itself: the foreground process's name ("zsh",
    /// "vim", "grok"), which the daemon reports and which stays short and
    /// stable while programs retitle at will. Falls back to the reported
    /// title, then the endpoint, for transports that never report one.
    var displayTitle: String {
        let process = store.processName
        if !process.isEmpty { return process }
        return reportedTitle.isEmpty ? store.endpointDescription : reportedTitle
    }

    /// The line under the process name: what the session says about itself
    /// — the shell-reported title (OSC 2) or the last watched command —
    /// and the endpoint when it says nothing. Never repeats `displayTitle`:
    /// with no process name the reported title is already the first line,
    /// so this yields the endpoint instead.
    var secondaryTitle: String {
        if store.processName.isEmpty { return store.endpointDescription }
        return reportedTitle.isEmpty ? store.endpointDescription : reportedTitle
    }

    /// The reported title without the endpoint fallback, for the places
    /// that have a better name of their own for a session that never
    /// reported one — the Live Activity, whose widget labels it with the
    /// shell instead. Trailing whitespace is trimmed: programs pad their
    /// OSC 2 titles, and the tab bar would carry the padding.
    var reportedTitle: String {
        let raw = terminal.title.isEmpty ? store.inferredTitle : terminal.title
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
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
           let id = transport.currentSessionID {
            transport.closeSession()
            DaemonSessionDirectory.shared.evict(id)
        } else if let id = daemonSession.id {
            XPCDaemonTransport.killSession(id)
            DaemonSessionDirectory.shared.evict(id)
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

/// Post-init bridge between the transport's exit callback (transport queue,
/// wired inside a factory closure that predates the store) and the store the
/// exit must reach.
final class ProcessExitRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var _handler: (@Sendable (Int32) -> Void)?

    var handler: (@Sendable (Int32) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _handler
        }
        set {
            lock.lock()
            _handler = newValue
            lock.unlock()
        }
    }

    func fire(_ status: Int32) {
        handler?(status)
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
