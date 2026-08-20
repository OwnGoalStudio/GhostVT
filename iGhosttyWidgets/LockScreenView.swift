//
//  LockScreenView.swift
//  iGhosttyWidgets
//

import SwiftUI
import WidgetKit

/// The Live Activity's lock screen card, laid out like a notification — the
/// app icon on the left, the app name in bold beside it, the content
/// underneath — because that is the shape everything else on that screen has.
/// Within the content every line shares one font and size; weight and opacity
/// alone carry the hierarchy.
struct LockScreenView: View {
    let state: TerminalSessionAttributes.ContentState

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            AppIconMark(size: 38)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("iGhostty")
                        .font(.subheadline.weight(.bold))
                    Spacer(minLength: 8)
                    Text("\(state.totalCount)")
                        .font(.subheadline.monospacedDigit())
                        .opacity(0.5)
                }
                if !state.sessions.isEmpty {
                    SessionList(state: state, limit: 4, font: .subheadline)
                }
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 14)
        // nil tint = the system's frosted material, which follows light/dark
        // on its own — a fixed tint would need the color scheme pinned to
        // keep the semantic text colors legible.
        .activityBackgroundTint(nil)
        .activitySystemActionForegroundColor(Palette.accent)
    }
}
