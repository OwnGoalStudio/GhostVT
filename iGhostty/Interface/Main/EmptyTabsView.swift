//
//  EmptyTabsView.swift
//  iGhostty
//

import SwiftUI

/// What a window shows once its last tab is closed. Closing everything is
/// allowed — the window stays open, and only a tap here (or the bar's `+`)
/// opens the next shell.
struct EmptyTabsView: View {
    let onNewTab: () -> Void

    var body: some View {
        VStack(spacing: DS.Padding.l) {
            Image(systemName: "terminal")
                .font(DS.Font.heroSymbol)
                .foregroundColor(.secondary)
            Text("No Open Tabs")
                .font(DS.Font.title)
            Text("Start a new tab to keep working.")
                .font(DS.Font.label)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button(action: onNewTab) {
                Label("New Tab", systemImage: "plus")
                    .font(DS.Font.controlEmphasis)
                    .padding(.horizontal, DS.Padding.s)
                    .padding(.vertical, DS.Padding.xs)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, DS.Padding.s)
        }
        .padding(DS.Padding.xl)
        .frame(maxWidth: 360)
        // Greedy on purpose: with no tabs this view is the whole terminal
        // column, and the top bar hangs off that column as a safe-area inset
        // — its width is the column's width. Without this the column shrinks
        // to the card's ideal size and drags the bar with it.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
