//
//  SessionStatusOverlay.swift
//  iGhostVT
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
/// screen. An exited session's card offers Close Tab as the emphasized
/// default — a finished shell is nearly always a finished tab — and Keep Tab
/// as the quieter way to keep the scrollback around and selectable.
struct SessionStatusOverlay: View {
    @ObservedObject var store: TerminalSessionStore

    /// Closes the tab this session belongs to; provided by the pane's owner.
    var onCloseTab: () -> Void

    /// The failure the user dismissed with Keep Tab. Stored as the dismissed
    /// status so a later, different failure (or a reconnect cycle) presents
    /// its own card again.
    @State private var acknowledged: TerminalSessionStore.Status?

    var body: some View {
        content
            .animation(DS.Motion.smooth, value: store.status)
    }

    @ViewBuilder
    private var content: some View {
        switch store.status {
        case .idle, .connecting:
            // Idle means the surface hasn't reported its grid yet — normally
            // milliseconds, but if it sticks the pill is the only sign the
            // window isn't just an empty terminal.
            HStack(spacing: DS.Padding.s) {
                ProgressView()
                Text(store.status == .idle ? "Starting…" : "Connecting…")
                    .font(DS.Font.labelEmphasis)
            }
            .padding(.horizontal, DS.Padding.l)
            .padding(.vertical, DS.Padding.m)
            .barGlass(in: Capsule(), interactive: false)
            .transition(.opacity)

        case let .failed(reason):
            if acknowledged != store.status {
                ZStack {
                    Color.black.opacity(0.25)
                    alertCard(reason: reason)
                        .padding(DS.Padding.l)
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
            actions: processExited
                ? [
                    AlertAction("Keep Tab") {
                        acknowledged = store.status
                    },
                    AlertAction("Close Tab", kind: .accent) {
                        onCloseTab()
                    },
                ]
                : [
                    AlertAction("Close Tab") {
                        onCloseTab()
                    },
                    AlertAction("Retry", kind: .accent) {
                        store.connect()
                    },
                ]
        )
    }
}
