//
//  SessionStatusOverlay.swift
//  iGhostty
//

import SwiftUI
import UIKit

/// Covers the terminal while its session is not usable: a quiet pill while
/// the surface starts up or the daemon connection opens, and an alert card
/// once the session ended or the connection failed. Connected shows nothing.
///
/// The card is the shared `AlertCardView` — the same design
/// `AlertViewController` presents — drawn inline over the pane rather than
/// presented, because it must persist while the dead terminal stays on
/// screen. An exited session's card is dismissable (Done): the scrollback
/// stays selectable, and only Close actually takes the tab down.
struct SessionStatusOverlay: View {
    @ObservedObject var store: TerminalSessionStore

    /// Closes the tab this session belongs to; provided by the pane's owner.
    var onCloseTab: () -> Void

    /// The failure the user dismissed with Done. Stored as the dismissed
    /// status so a later, different failure (or a reconnect cycle) presents
    /// its own card again.
    @State private var acknowledged: TerminalSessionStore.Status?

    var body: some View {
        content
            .animation(.easeInOut(duration: 0.2), value: store.status)
    }

    @ViewBuilder
    private var content: some View {
        switch store.status {
        case .idle, .connecting:
            // Idle means the surface hasn't reported its grid yet — normally
            // milliseconds, but if it sticks the pill is the only sign the
            // window isn't just an empty terminal.
            HStack(spacing: 10) {
                ProgressView()
                Text(store.status == .idle ? "Starting…" : "Connecting…")
                    .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .barGlass(in: Capsule(), interactive: false)
            .transition(.opacity)

        case let .failed(reason):
            if acknowledged != store.status {
                ZStack {
                    Color.black.opacity(0.25)
                    alertCard(reason: reason)
                        .padding(16)
                }
                .transition(.opacity)
            }

        case .connected:
            EmptyView()
        }
    }

    private var processExited: Bool {
        store.processExitStatus != nil
    }

    private func alertCard(reason: String) -> some View {
        AlertCardView(
            title: processExited
                ? String(localized: "Session Ended")
                : String(localized: "Terminal Unavailable"),
            message: reason,
            actions: [
                AlertAction("Close") {
                    onCloseTab()
                },
                processExited
                    ? AlertAction("Done", kind: .accent, handler: {
                        acknowledged = store.status
                    })
                    : AlertAction("Retry", kind: .accent, handler: {
                        store.connect()
                    }),
            ]
        )
    }
}
