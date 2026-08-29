//
//  TabManager.swift
//  iGhostVT
//

import Foundation
import GhosttyTerminal
import SwiftUI

/// The tabs of one window. Owned by that window's `SceneDelegate`; every
/// interface component receives a reference and mutates tabs only through
/// this type.
///
/// Tab insertions and removals are wrapped in `withAnimation` here, so every
/// view of the tab list (panes, strip, sidebar, switcher grid) animates the
/// same change together instead of each view guessing on its own.
@MainActor
final class TabManager: ObservableObject {
    /// One curve for every tab mutation, so a close reads the same in the
    /// strip, the sidebar, and the pane it removes.
    static let tabTransition = DS.Motion.structure
    @Published private(set) var tabs: [TerminalTab] = []
    @Published var activeTabID: UUID? {
        didSet { syncSurfaceVisibility() }
    }

    /// A close awaiting the user's confirmation; presented as one alert by
    /// whichever context owns the screen (see `CloseTabConfirmation`), so
    /// the four close entry points cannot race each other's presentations.
    @Published var closeRequest: TerminalTab?

    /// Clipboard decisions libghostty is waiting on (a program's OSC 52
    /// read or write, a paste that paste protection flagged), answered one
    /// at a time: `ClipboardConfirmation` presents the head the way
    /// `closeRequest` is presented. Every tab's hook is installed by
    /// `makeTab`, so no tab can exist without one and fall back to
    /// libghostty's silent denial.
    @Published private(set) var clipboardRequests: [TerminalClipboardConfirmationRequest] = []

    /// A long press asking for the selection sheet; `RootView` presents it.
    @Published var selectionRequest: TerminalSelectionRequestBox?

    init() {
        SessionActivityController.shared.register(self) { [weak self] in
            self.map {
                SessionActivityController.WindowSnapshot(
                    tabs: $0.tabs,
                    activeTabID: $0.activeTabID
                )
            }
        }
        // The first window of a cold launch asks the daemon what survived the
        // previous run and reattaches to it; every other window (and a launch
        // with nothing to resume) starts with one fresh tab. The daemon is
        // the only record — nothing about sessions is persisted app-side.
        DaemonSessionDirectory.shared.claimResumable { [weak self] resumable in
            guard let self else { return }
            guard !resumable.isEmpty else {
                if tabs.isEmpty { newTab() }
                return
            }
            let resumed = resumable.map { self.makeTab(resume: $0) }
            withAnimation(Self.tabTransition) {
                self.tabs.append(contentsOf: resumed)
                self.activeTabID = self.tabs.last?.id
            }
            if self.isSceneActive {
                for tab in self.tabs {
                    tab.store.noteSceneActive()
                }
            }
            SessionActivityController.shared.refresh()
        }
    }

    var activeTab: TerminalTab? {
        tabs.first { $0.id == activeTabID }
    }

    /// Only the active tab's surface draws. The panes keep every tab mounted
    /// behind an opacity flip, and without this the hidden ones keep a live
    /// display link, rendering frames nobody sees; marking them invisible
    /// keeps grid, scrollback, and session while rendering stops
    /// (`TerminalViewState.isSurfaceVisible`).
    private func syncSurfaceVisibility() {
        for tab in tabs {
            let visible = tab.id == activeTabID
            if tab.terminal.isSurfaceVisible != visible {
                tab.terminal.isSurfaceVisible = visible
            }
        }
    }

    /// Whether the owning scene has reached foreground-active. Sessions
    /// auto-connect only after it: daemon work stays out of the launch
    /// transition, whose transient layout otherwise sizes the first shell.
    private var isSceneActive = false

    /// Scene-delegate signal; also replayed onto tabs created before the
    /// scene came up (the cold-launch resume batch).
    func noteSceneActive() {
        isSceneActive = true
        for tab in tabs {
            tab.store.noteSceneActive()
        }
    }

    /// Reconnects the tabs that are sitting on a failure.
    ///
    /// `noteSceneActive()` cannot do this: the store's auto-connect fires
    /// exactly once, so a second call is a no-op for a tab that already tried
    /// and failed. On the Mac the first attempt can fail for a reason outside
    /// the app — the background helper was not approved yet — and when that
    /// clears, these tabs deserve the attempt they would have got had the
    /// helper been there at launch.
    func retryFailedTabs() {
        for tab in tabs where tab.store.hasFailed {
            tab.store.connect()
        }
    }

    /// The one way a tab is created: its terminal's hooks land on this
    /// window's presenters before the tab joins `tabs`.
    private func makeTab(resume daemonSessionID: UInt64? = nil) -> TerminalTab {
        let tab = TerminalTab(resumeDaemonSessionID: daemonSessionID)
        tab.terminal.onClipboardConfirmationRequest = { [weak self] request in
            self?.clipboardRequests.append(request)
        }
        tab.terminal.onTextSelectionRequest = { [weak self] request in
            self?.selectionRequest = TerminalSelectionRequestBox(request: request)
        }
        // A finished shell is nearly always a finished tab. With the setting
        // on, skip the Session Ended card and close outright — straight to
        // `close`, not `requestClose`: the confirmation guards a running
        // program, and this one is already gone. On a dead session `close` only
        // clears the daemon's record of it.
        tab.onSessionExit = { [weak self, weak tab] in
            guard SessionAutoClose.isEnabled, let self, let tab else { return }
            self.close(tab)
        }
        return tab
    }

    /// The presenter answered the head of `clipboardRequests`.
    func finishClipboardRequest() {
        guard !clipboardRequests.isEmpty else { return }
        clipboardRequests.removeFirst()
    }

    @discardableResult
    func newTab() -> TerminalTab {
        let tab = makeTab()
        withAnimation(Self.tabTransition) {
            tabs.append(tab)
            activeTabID = tab.id
        }
        if isSceneActive {
            tab.store.noteSceneActive()
        }
        SessionActivityController.shared.refresh()
        return tab
    }

    /// Closing the last tab leaves the window empty on purpose: the empty
    /// state offers a fresh terminal, and only a user's tap opens one. The
    /// old auto-replacement spawned its tab from inside the close (sometimes
    /// underneath the tab switcher's full-screen cover, where no surface can
    /// attach), which is exactly the kind of half-mounted terminal that gets
    /// stuck on its connect.
    func close(_ tab: TerminalTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else {
            return
        }
        tab.close()
        withAnimation(Self.tabTransition) {
            tabs.remove(at: index)
            if activeTabID == tab.id {
                activeTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
            }
        }
        SessionActivityController.shared.refresh()
    }

    /// The path every close control takes: ask first when a running program
    /// would die with the tab, close straight away when there is nothing to
    /// lose — no session, or a shell idling at its prompt.
    func requestClose(_ tab: TerminalTab) {
        if tab.hasRunningProgram {
            closeRequest = tab
        } else {
            close(tab)
        }
    }

    /// Scene teardown: the window is gone, but its shells belong to the
    /// daemon — detach so they survive for the next launch. Named apart from
    /// `closeAll()` because the difference is the whole point: this one keeps
    /// the shells running, that one kills them.
    func detachAllTabs() {
        for tab in tabs {
            tab.detach()
        }
        tabs.removeAll()
        activeTabID = nil
        SessionActivityController.shared.refresh()
    }

    /// The user emptied the window from the tab switcher: every shell dies,
    /// exactly as it would from its own ×. Confirmed by the caller.
    func closeAll() {
        for tab in tabs {
            tab.close()
        }
        withAnimation(Self.tabTransition) {
            tabs.removeAll()
            activeTabID = nil
        }
        SessionActivityController.shared.refresh()
    }

    /// Whether closing everything would interrupt a running program — the
    /// case worth a confirmation, mirroring `requestClose(_:)` for a single
    /// tab.
    var hasRunningPrograms: Bool {
        tabs.contains { $0.hasRunningProgram }
    }

    func activateAdjacentTab(offset: Int) {
        guard
            let activeTabID,
            let index = tabs.firstIndex(where: { $0.id == activeTabID })
        else { return }
        let next = (index + offset + tabs.count) % tabs.count
        self.activeTabID = tabs[next].id
    }
}

/// Wraps a selection request for SwiftUI's `sheet(item:)`; each long press is
/// its own presentation.
struct TerminalSelectionRequestBox: Identifiable {
    let id = UUID()
    let request: TerminalTextSelectionRequest
}

/// Whether a tab closes by itself when its session ends. Off by default:
/// the Session Ended card leaves the scrollback on screen, and a shell that
/// died unexpectedly is exactly when someone wants to read it. On is for the
/// workflow where every tab is a one-shot command whose end means "done".
enum SessionAutoClose {
    static let key = "Session.autoCloseTab"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: key)
    }
}
