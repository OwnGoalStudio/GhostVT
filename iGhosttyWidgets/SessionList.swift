//
//  SessionList.swift
//  iGhosttyWidgets
//

import SwiftUI

/// The session rows both presentations share — the lock screen card is the
/// roomier rendition of the island's bottom region, not a different design.
struct SessionList: View {
    let state: TerminalSessionAttributes.ContentState
    let limit: Int
    /// Every line in the list wears this one font at this one size; bold vs
    /// regular and opacity are the only distinctions, notification-style.
    let font: Font

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(state.sessions.prefix(limit)) { session in
                SessionRow(session: session, font: font)
            }
            if let footer {
                Text(footer)
                    .font(font)
                    .opacity(0.4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What didn't fit, plus what has no tab at all. Both are worth a line:
    /// a detached session is still burning a shell in the daemon.
    private var footer: String? {
        var parts: [String] = []
        let hidden = max(0, state.sessions.count - limit) + state.overflowCount
        if hidden > 0 {
            parts.append(String.localizedStringWithFormat(
                NSLocalizedString("+%lld more", comment: "Sessions that did not fit the list"),
                hidden
            ))
        }
        if state.detachedCount > 0 {
            parts.append(String.localizedStringWithFormat(
                NSLocalizedString("%lld detached", comment: "Sessions with no tab attached"),
                state.detachedCount
            ))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }
}

private struct SessionRow: View {
    let session: TerminalSessionAttributes.Session
    let font: Font

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(
                status: session.status,
                isActive: session.isActive,
                diameter: 6
            )
            Text(session.headline)
                .font(font)
                .fontWeight(session.isActive ? .bold : .regular)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 10)
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
            return String.localizedStringWithFormat(
                NSLocalizedString(
                    "Session %lld",
                    comment: "Name of a shell that has not set a title"
                ),
                Int(clamping: number)
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
