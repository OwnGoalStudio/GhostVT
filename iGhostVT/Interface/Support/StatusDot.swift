import SwiftUI

/// Connection state as a filled circle glyph. It is an SF Symbol rather than a
/// `Circle` shape so it sits on the same baseline and scales with the text
/// beside it — pass the neighbouring title's font.
struct StatusDot: View {
    let status: TerminalSessionStore.Status
    var font: DS.Font = .label

    var body: some View {
        Image(systemName: "circle.fill")
            .font(font)
            .imageScale(.small)
            .foregroundColor(color)
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
        case .idle: "Not Connected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .failed: "Connection Failed"
        }
    }
}
