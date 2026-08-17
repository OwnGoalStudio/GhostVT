import SwiftUI

/// Confirmation for closing a tab. Close is a kill, not a detach: the daemon
/// SIGHUPs the shell and reclaims it moments later, and the ledger entry goes
/// with it, so there is no undo and no reattach. A stray tap on an × must not
/// destroy a live shell silently.
///
/// Attached once per presentation context: the tab switcher is a full-screen
/// cover, and a covered context cannot present an alert — so the switcher
/// carries its own copy and the root's stands down (`isActive: false`) while
/// the switcher is up.
struct CloseTabConfirmation: ViewModifier {
    @ObservedObject var tabManager: TabManager
    var isActive = true

    func body(content: Content) -> some View {
        content.alert(
            Text("Close “\(tabManager.closeRequest?.displayTitle ?? "")”?"),
            isPresented: Binding(
                get: { isActive && tabManager.closeRequest != nil },
                set: { presented in
                    if !presented {
                        tabManager.closeRequest = nil
                    }
                }
            ),
            presenting: tabManager.closeRequest
        ) { tab in
            Button("Close Tab", role: .destructive) {
                tabManager.close(tab)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This closes the terminal and stops everything running in it.")
        }
    }
}

extension View {
    func closeTabConfirmation(_ tabManager: TabManager, isActive: Bool = true) -> some View {
        modifier(CloseTabConfirmation(tabManager: tabManager, isActive: isActive))
    }
}
