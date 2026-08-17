//
//  TerminalSessionActivityWidget.swift
//  iGhosttyWidgets
//

import ActivityKit
import SwiftUI
import WidgetKit

/// Dynamic Island + Lock Screen presentation of the running terminal sessions.
///
/// Both presentations are built from the same row — a status dot, what the
/// shell calls itself, and where it is — so the lock screen reads as the
/// roomier version of the island rather than a different design.
///
/// The expanded island puts every word in the bottom region: it is the only
/// one wide enough for a path, and the center region sits under whatever else
/// the system (or a tweak) draws beside the camera, where text collides.
struct TerminalSessionActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TerminalSessionAttributes.self) { context in
            LockScreenView(state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 5) {
                        TerminalMark(size: 15)
                        Text("\(context.state.totalCount)")
                            .font(.callout.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Palette.accent)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    StatusDots(sessions: context.state.sessions)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    SessionList(state: context.state, limit: 3, compact: true)
                        .padding(.horizontal, 6)
                        .padding(.top, 4)
                        .padding(.bottom, 2)
                }
            } compactLeading: {
                TerminalMark(size: 14)
            } compactTrailing: {
                Text("\(context.state.totalCount)")
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Palette.accent)
            } minimal: {
                TerminalMark(size: 14)
            }
        }
    }
}

// MARK: - Lock screen

private struct LockScreenView: View {
    let state: TerminalSessionAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                TerminalMark(size: 16)
                Text("iGhostty")
                    .font(.footnote.weight(.semibold))
                Spacer(minLength: 8)
                CountBadge(count: state.totalCount)
            }
            if !state.sessions.isEmpty {
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: 1)
                SessionList(state: state, limit: 4, compact: false)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        // The tint below is dark no matter what the system looks like, so the
        // semantic colors (.primary/.secondary/.tertiary) must resolve dark
        // too — in light mode they'd come out black-on-black otherwise.
        .environment(\.colorScheme, .dark)
        .activityBackgroundTint(Color.black.opacity(0.55))
        .activitySystemActionForegroundColor(Palette.accent)
    }
}

// MARK: - Shared pieces

private struct SessionList: View {
    let state: TerminalSessionAttributes.ContentState
    let limit: Int
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 7) {
            ForEach(state.sessions.prefix(limit)) { session in
                SessionRow(session: session, compact: compact)
            }
            if let footer {
                Text(footer)
                    .font(compact ? .caption2 : .caption)
                    .foregroundStyle(.tertiary)
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
    let compact: Bool

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(
                status: session.status,
                isActive: session.isActive,
                diameter: compact ? 6 : 7
            )
            Text(session.headline)
                .font(.system(compact ? .caption : .subheadline, design: .monospaced))
                .fontWeight(session.isActive ? .semibold : .regular)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 10)
            if let detail = session.detail {
                Text(detail)
                    // Truncating the head keeps the leaf directory visible,
                    // which is the part that tells sessions apart.
                    .font(.system(compact ? .caption2 : .caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .layoutPriority(-1)
            }
        }
    }
}

/// One dot per session in the expanded island's trailing region — a glance
/// tells you whether they are all up without reading the list.
private struct StatusDots: View {
    let sessions: [TerminalSessionAttributes.Session]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(sessions.prefix(5)) { session in
                StatusDot(status: session.status, isActive: session.isActive, diameter: 6)
            }
        }
    }
}

private struct StatusDot: View {
    let status: TerminalSessionAttributes.Session.Status
    var isActive: Bool = false
    var diameter: CGFloat = 7

    var body: some View {
        // The halo is always laid out, only sometimes painted, so the active
        // tab moving between rows doesn't shift the text beside it.
        ZStack {
            Circle()
                .fill(color.opacity(isActive ? 0.28 : 0))
                .frame(width: diameter + 6, height: diameter + 6)
            Circle()
                .fill(color)
                .frame(width: diameter, height: diameter)
        }
        .frame(width: diameter + 6, height: diameter + 6)
    }

    private var color: Color {
        switch status {
        case .starting: return Palette.starting
        case .live: return Palette.accent
        case .failed: return Palette.failed
        }
    }
}

private struct CountBadge: View {
    let count: Int

    var body: some View {
        // The number alone: "1 sessions" is the plural bug every localisation
        // of this badge walks into, and the terminal mark beside it already
        // says what is being counted.
        Text("\(count)")
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(Palette.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Capsule().fill(Palette.accent.opacity(0.16)))
    }
}

private struct TerminalMark: View {
    var size: CGFloat = 15

    var body: some View {
        Image(systemName: "apple.terminal")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Palette.accent)
    }
}

private enum Palette {
    /// Close to the prompt green the terminal itself renders, rather than
    /// the system green, so the widget reads as part of the app.
    static let accent = Color(red: 0.29, green: 0.85, blue: 0.44)
    static let starting = Color(red: 1.00, green: 0.72, blue: 0.20)
    static let failed = Color(red: 1.00, green: 0.38, blue: 0.36)
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
