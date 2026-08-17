//
//  SessionStatusOverlay.swift
//  iGhostty
//

import SwiftUI

/// Covers the terminal while its session is not usable: a quiet pill while
/// the surface starts up or the daemon connection opens, and a retryable
/// error card once a connection has failed. Connected shows nothing.
struct SessionStatusOverlay: View {
    @ObservedObject var store: TerminalSessionStore

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
            VStack(spacing: 14) {
                Image(systemName: "bolt.horizontal.circle")
                    .font(.system(size: 42, weight: .light))
                    .foregroundColor(.secondary)
                Text("Terminal Unavailable")
                    .font(.headline)
                Text(reason)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                Button("Retry") {
                    store.connect()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(28)
            .frame(maxWidth: 320)
            .barGlass(
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .padding(24)
            .transition(.opacity)

        case .connected:
            EmptyView()
        }
    }
}
