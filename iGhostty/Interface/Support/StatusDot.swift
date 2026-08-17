import SwiftUI

struct StatusDot: View {
    let status: TerminalSessionStore.Status

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityLabel(accessibilityDescription)
    }

    private var color: Color {
        switch status {
        case .idle: .gray
        case .connecting: .yellow
        case .connected: .green
        case .failed: .red
        }
    }

    private var accessibilityDescription: LocalizedStringKey {
        switch status {
        case .idle: "Offline"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .failed: "Connection failed"
        }
    }
}
