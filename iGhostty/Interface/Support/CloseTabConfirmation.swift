import SwiftUI
import UIKit

/// Confirmation for closing a tab. Close is a kill, not a detach: the daemon
/// SIGHUPs the shell and reclaims it moments later, and the ledger entry goes
/// with it, so there is no undo and no reattach. A stray tap on an × must not
/// destroy a live shell silently.
///
/// Attached once, at the window root. The alert is a presented
/// `AlertViewController`, which lands on the window's front-most presentation
/// context — so a request raised under the tab switcher's full-screen cover
/// presents above the switcher, and no second copy of this modifier is needed
/// the way the covered `.alert` used to demand.
struct CloseTabConfirmation: ViewModifier {
    @ObservedObject var tabManager: TabManager
    @State private var window: UIWindow?
    @State private var presented: AlertViewController?

    func body(content: Content) -> some View {
        content
            .background(WindowReader(window: $window))
            .onReceive(tabManager.$closeRequest) { tab in
                guard let tab, presented == nil else { return }
                present(for: tab)
            }
    }

    private func present(for tab: TerminalTab) {
        guard let window else { return }
        let alert = AlertViewController(
            title: "Close “\(tab.displayTitle)”?",
            message: "This closes the terminal and stops everything running in it.",
            actions: [
                AlertAction("Cancel") {
                    finish()
                },
                AlertAction("Close Tab", kind: .destructive) {
                    tabManager.close(tab)
                    finish()
                },
            ]
        )
        presented = alert
        alert.present(in: window)
    }

    private func finish() {
        tabManager.closeRequest = nil
        presented = nil
    }
}

extension View {
    func closeTabConfirmation(_ tabManager: TabManager) -> some View {
        modifier(CloseTabConfirmation(tabManager: tabManager))
    }
}
