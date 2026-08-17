//
//  TabManager.swift
//  iGhostty
//

import Foundation
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
    static let tabTransition = Animation.spring(response: 0.35, dampingFraction: 0.85)
    @Published private(set) var tabs: [TerminalTab] = []
    @Published var activeTabID: UUID?

    /// A close awaiting the user's confirmation; presented as one alert by
    /// whichever context owns the screen (see `CloseTabConfirmation`), so
    /// the four close entry points cannot race each other's presentations.
    @Published var closeRequest: TerminalTab?

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
            withAnimation(Self.tabTransition) {
                self.tabs.append(
                    contentsOf: resumable.map { TerminalTab(resumeDaemonSessionID: $0) }
                )
                self.activeTabID = self.tabs.last?.id
            }
            SessionActivityController.shared.refresh()
        }
    }

    var activeTab: TerminalTab? {
        tabs.first { $0.id == activeTabID }
    }

    @discardableResult
    func newTab() -> TerminalTab {
        let tab = TerminalTab()
        withAnimation(Self.tabTransition) {
            tabs.append(tab)
            activeTabID = tab.id
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

    /// The path every close control takes: ask first when a live shell would
    /// die with the tab, close straight away when there is nothing to lose.
    func requestClose(_ tab: TerminalTab) {
        if tab.hasLiveSession {
            closeRequest = tab
        } else {
            close(tab)
        }
    }

    /// Scene teardown: the window is gone, but its shells belong to the
    /// daemon — detach so they survive for the next launch.
    func closeAllTabs() {
        for tab in tabs {
            tab.detach()
        }
        tabs.removeAll()
        activeTabID = nil
        SessionActivityController.shared.refresh()
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
