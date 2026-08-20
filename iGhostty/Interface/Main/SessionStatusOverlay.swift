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
/// The card is a SwiftUI rendition of Lakr233/AlertController's design —
/// dimmed pane, centered material card, app-icon header, and a two-button
/// row whose right action carries the accent. An exited session's card is
/// dismissable (Done): the dead terminal stays on screen with its scrollback
/// selectable, and only Close actually takes the tab down.
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
        VStack(spacing: 16) {
            Image("AlertIcon")
                .resizable()
                .scaledToFill()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text(processExited ? "Session Ended" : "Terminal Unavailable")
                .font(.body.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(reason)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .lineLimit(6)

            HStack(spacing: 8) {
                alertButton("Close", style: .normal) {
                    onCloseTab()
                }
                if processExited {
                    alertButton("Done", style: .accent) {
                        acknowledged = store.status
                    }
                } else {
                    alertButton("Retry", style: .accent) {
                        store.connect()
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: 350)
        .background(.regularMaterial)
        .background(Color(UIColor.systemBackground).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func alertButton(
        _ title: LocalizedStringKey,
        style: AlertButtonStyle.Kind,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
        }
        .buttonStyle(AlertButtonStyle(kind: style))
    }
}

/// AlertController's button, translated: full-width rounded rectangle with a
/// 1pt accent border; the accent action fills with the accent color and
/// speaks semibold, the normal one stays clear with accent-colored text.
struct AlertButtonStyle: ButtonStyle {
    enum Kind {
        case normal
        case accent
    }

    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(kind == .accent ? .body.weight(.semibold) : .body)
            .foregroundColor(kind == .accent ? .white : .accentColor)
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(kind == .accent ? Color.accentColor : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
