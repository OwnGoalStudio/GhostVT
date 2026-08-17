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
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 52, weight: .light))
                .foregroundColor(.secondary)
            Text("No Open Tabs")
                .font(.headline)
            Text("Closed shells are gone for good; a new tab starts a fresh one.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button(action: onNewTab) {
                Label("New Terminal", systemImage: "plus")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: 360)
    }
}
