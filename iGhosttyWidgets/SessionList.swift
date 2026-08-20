//
//  SessionList.swift
//  iGhosttyWidgets
//

import SwiftUI

/// Rows past this are only counted, not listed; more than this stops reading
/// as a glanceable card in either presentation.
private let maxRows = 3

/// The session rows both presentations share — the lock screen card is the
/// roomier rendition of the island's bottom region, not a different design.
struct SessionList: View {
    let state: TerminalSessionAttributes.ContentState
    /// Every line in the list wears this one font at this one size; bold vs
    /// regular and opacity are the only distinctions, notification-style.
    let font: Font

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.line) {
            // The ForEach is keyed by session id, so an update moves the
            // rows that survived and transitions only the ones that didn't —
            // without the explicit animation the whole card just snaps.
            ForEach(state.sessions.prefix(maxRows)) { session in
                SessionRow(session: session, font: font)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.35), value: state)
    }
}

extension TerminalSessionAttributes.ContentState {
    /// What the corner count reads: the plain total while every session is
    /// listed, "shown/total" once any are only counted — the list itself
    /// never says what it dropped.
    var countLabel: String {
        let shown = min(sessions.count, maxRows)
        return totalCount > shown ? "\(shown)/\(totalCount)" : "\(totalCount)"
    }
}

private struct SessionRow: View {
    let session: TerminalSessionAttributes.Session
    let font: Font

    var body: some View {
        HStack(spacing: Spacing.line) {
            StatusDot(status: session.status)
            Text(session.headline)
                .font(font)
                .fontWeight(session.isActive ? .bold : .regular)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Spacing.line)
            if let detail = session.detail {
                Text(detail)
                    // Truncating the head keeps the leaf directory visible,
                    // which is the part that tells sessions apart.
                    .font(font)
                    .opacity(0.5)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .layoutPriority(-1)
            }
        }
    }
}

private extension TerminalSessionAttributes.Session {
    /// The best name we have, in the order the user would recognise it.
    var headline: String {
        if !title.isEmpty { return title }
        if !shell.isEmpty { return shell }
        if let number {
            return String(
                localized: "Session \(Int(clamping: number))",
                comment: "Name of a shell that has not set a title"
            )
        }
        return String(localized: "Terminal")
    }

    /// The right-hand column: where the shell is, or why it isn't there yet.
    var detail: String? {
        switch status {
        case .starting: return String(localized: "Starting…")
        case .failed: return String(localized: "Failed")
        case .live: return directory.isEmpty ? nil : directory
        }
    }
}
