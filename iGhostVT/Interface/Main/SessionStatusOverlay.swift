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
///
/// The launch agent is consulted *before* the session, because on a fresh Mac
/// install the session cannot possibly connect: nothing has started the daemon
/// yet. Reading `store.status` first would leave a person watching a
/// "Connecting…" pill that never resolves, when the actual next step is one
/// approval in Login Items.
struct SessionStatusOverlay: View {
    @ObservedObject var store: TerminalSessionStore
    @ObservedObject private var agent = MacLaunchAgent.shared

    /// Closes the tab this session belongs to; provided by the pane's owner.
    var onCloseTab: () -> Void

    /// The failure the user dismissed with Keep Tab. Stored as the dismissed
    /// status so a later, different failure (or a reconnect cycle) presents
    /// its own card again.
    @State private var acknowledged: TerminalSessionStore.Status?

    var body: some View {
        content
            .animation(DS.Motion.smooth, value: store.status)
            .animation(DS.Motion.smooth, value: agent.status)
    }

    @ViewBuilder
    private var content: some View {
        if agent.isReady {
            sessionContent
        } else {
            ZStack {
                Color.black.opacity(0.25)
                agentCard
                    .padding(DS.Padding.l)
            }
            .transition(.opacity)
        }
    }

    /// The one thing standing between a fresh install and a terminal, said
    /// plainly. Every state names its own next step, and none of them is
    /// "retry the connection" — the connection is not what is missing.
    @ViewBuilder
    private var agentCard: some View {
        switch agent.status {
        case .needsRelocation:
            AlertCardView(
                title: String(localized: "Move iGhostVT to Applications"),
                message: String(
                    localized: """
                    iGhostVT runs its terminals through a background helper that \
                    starts with your Mac. Drag iGhostVT to your Applications \
                    folder and open it from there, so the helper keeps working \
                    after you close this window.
                    """
                ),
                actions: [AlertAction("Check Again", kind: .accent) { agent.refresh() }]
            )
        case .notRegistered:
            AlertCardView(
                title: String(localized: "Turn On the Terminal Helper"),
                message: String(
                    localized: """
                    The background helper that runs your terminals is switched \
                    off. Turn it back on to open a terminal.
                    """
                ),
                actions: [AlertAction("Turn On Helper", kind: .accent) { agent.activate() }]
            )
        case .needsApproval:
            AlertCardView(
                title: String(localized: "Allow the Terminal Helper"),
                message: String(
                    localized: """
                    iGhostVT needs its background helper before it can open a \
                    terminal. Turn on iGhostVT under Login Items in System \
                    Settings.
                    """
                ),
                actions: [
                    AlertAction("Check Again") { agent.refresh() },
                    AlertAction("Open Login Items", kind: .accent) {
                        agent.openLoginItemsSettings()
                    },
                ]
            )
        case let .failed(reason):
            AlertCardView(
                title: String(localized: "Terminal Helper Unavailable"),
                message: reason,
                actions: [
                    AlertAction("Check Again") { agent.refresh() },
                    AlertAction("Try Again", kind: .accent) { agent.activate() },
                ]
            )
        case .notApplicable, .unsupported, .enabled:
            EmptyView()
        }
    }

    @ViewBuilder
    private var sessionContent: some View {
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
