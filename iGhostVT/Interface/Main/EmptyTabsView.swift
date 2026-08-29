//
//  EmptyTabsView.swift
//  iGhostVT
//

import SwiftUI

/// What a window shows once its last tab is closed. Closing everything is
/// allowed — the window stays open, and the bar's `+` (or ⌘T) opens the next
/// shell; this view offers nothing of its own.
///
/// A prompt glyph and a title, in the theme's text colour on the theme's
/// background — the pane behind this view is the theme's background whatever
/// the system scheme says, so the label colour would not do.
struct EmptyTabsView: View {
    @ObservedObject private var theme = AppTheme.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        VStack(spacing: DS.Padding.l) {
            Text(verbatim: "❯")
                .font(DS.Font.heroPrompt)
                .foregroundColor(theme.foreground(for: colorScheme).opacity(0.7))
                .accessibilityHidden(true)
            Text("No Open Tabs")
                .font(DS.Font.title)
                .foregroundColor(theme.foreground(for: colorScheme))
        }
        .padding(DS.Padding.xl)
        // Greedy on purpose: with no tabs this view is the whole terminal
        // column, and the top bar hangs off that column as a safe-area inset
        // — its width is the column's width. Without this the column shrinks
        // to the text's ideal size and drags the bar with it.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            // Regular width only: on a phone the bottom bar owns that edge.
            if horizontalSizeClass == .regular {
                Text("An OwnGoal Studio Project with AI")
                    .font(DS.Font.caption)
                    .foregroundColor(theme.foreground(for: colorScheme).opacity(0.4))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DS.Padding.xl)
                    .padding(.bottom, DS.Padding.xl)
            }
        }
    }
}
