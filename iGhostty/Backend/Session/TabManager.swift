//
//  TabManager.swift
//  iGhostty
//

import Foundation

/// The tabs of one window. Owned by that window's `SceneDelegate`; every
/// interface component receives a reference and mutates tabs only through
/// this type.
@MainActor
final class TabManager: ObservableObject {
    @Published private(set) var tabs: [TerminalTab] = []
    @Published var activeTabID: UUID?

    /// A close awaiting the user's confirmation; presented as one alert by
    /// whichever context owns the screen (see `CloseTabConfirmation`), so
    /// the four close entry points cannot race each other's presentations.
    @Published var closeRequest: TerminalTab?

    init() {
        // The first window of a cold launch reattaches to the daemon
        // sessions that survived the previous run; every other window starts
        // with one fresh tab.
        let resumable = DaemonSessionLedger.shared.claimPersisted()
        if resumable.isEmpty {
            newTab()
        } else {
            tabs = resumable.map { TerminalTab(resumeDaemonSessionID: $0) }
            activeTabID = tabs.last?.id
        }
        SessionActivityController.shared.register(self) { [weak self] in
            self.map {
                SessionActivityController.WindowSnapshot(
                    tabs: $0.tabs,
                    activeTabID: $0.activeTabID
                )
            }
        }
    }

    var activeTab: TerminalTab? {
        tabs.first { $0.id == activeTabID }
    }

    @discardableResult
    func newTab() -> TerminalTab {
        let tab = TerminalTab()
        tabs.append(tab)
        activeTabID = tab.id
        SessionActivityController.shared.refresh()
        return tab
    }

    func close(_ tab: TerminalTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else {
            return
        }
        tab.close()
        tabs.remove(at: index)
        if tabs.isEmpty {
            newTab()
        } else if activeTabID == tab.id {
            activeTabID = tabs[min(index, tabs.count - 1)].id
        }
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
