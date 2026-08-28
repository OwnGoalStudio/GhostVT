//
//  LockScreenView.swift
//  iGhostVTWidgets
//

import SwiftUI
import WidgetKit

/// The summary card, shaped like Tesla's charging card: one big number, a
/// status bar under it, a couple of label/value pairs, and the ghost where
/// the car goes. Session titles and paths are the user's shell's data —
/// arbitrarily ugly — so the card shows only what the app controls: counts,
/// statuses, and the frontmost shell's name.
///
/// The lock screen and the expanded island both render this, identically.
struct SessionSummaryCard: View {
    let state: TerminalSessionAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.line) {
            HStack(alignment: .center, spacing: Spacing.line) {
                Text("iGhostVT")
                    .font(.subheadline.weight(.bold))
                Spacer(minLength: Spacing.line)
                if let shell = state.activeShell {
                    Text(shell)
                        .font(.subheadline)
                        .opacity(0.5)
                }
            }
            HStack(alignment: .center, spacing: Spacing.block) {
                VStack(alignment: .leading, spacing: Spacing.block) {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.line) {
                        Text("\(state.totalCount)")
                            .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                            .contentTransition(.numericText())
                        Text("total")
                            .font(.subheadline)
                            .opacity(0.5)
                    }
                    StatusBar(
                        live: state.liveCount,
                        starting: state.startingCount,
                        failed: state.failedCount
                    )
                    HStack(alignment: .top, spacing: Spacing.card) {
                        if let running = state.runningSummary {
                            InfoPair(label: "Running", value: running)
                        }
                        if state.detachedCount > 0 {
                            InfoPair(
                                label: "Detached",
                                value: String(
                                    localized: "\(state.detachedCount) in background",
                                    comment: "Sessions running with no tab attached"
                                )
                            )
                        }
                    }
                }
                Image("GhostGlyph")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 72)
            }
        }
        .padding(Spacing.card)
        .fontDesign(.rounded)
        .animation(.easeInOut(duration: 0.35), value: state)
    }
}

/// The card in its lock screen dress.
struct LockScreenView: View {
    @Environment(\.colorScheme) private var colorScheme

    let state: TerminalSessionAttributes.ContentState

    var body: some View {
        SessionSummaryCard(state: state)
            .activityBackgroundTint(colorScheme == .dark ? .black : .white)
            .activitySystemActionForegroundColor(Palette.accent)
    }
}

/// Tesla's charge bar, repurposed: one segment per status, sized by its
/// share of the listed sessions. All green means all live.
struct StatusBar: View {
    let live: Int
    let starting: Int
    let failed: Int

    private var total: Int { live + starting + failed }

    var body: some View {
        GeometryReader { geo in
            if total == 0 {
                Capsule()
                    .fill(.primary.opacity(0.12))
            } else {
                let groups: [(color: Color, count: Int)] = [
                    (Palette.accent, live),
                    (Palette.starting, starting),
                    (Palette.failed, failed),
                ].filter { $0.1 > 0 }
                let gaps = CGFloat(groups.count - 1) * Spacing.line
                HStack(spacing: Spacing.line) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                        Capsule()
                            .fill(group.color)
                            .frame(
                                width: (geo.size.width - gaps)
                                    * CGFloat(group.count) / CGFloat(total)
                            )
                    }
                }
            }
        }
        .frame(height: 6)
    }
}

/// A dim label over its value, both in the card's one text size.
private struct InfoPair: View {
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.subheadline)
                .opacity(0.5)
            Text(value)
                .font(.subheadline)
                .contentTransition(.numericText())
        }
    }
}

/// What the card and the island's status ring derive from the payload.
/// The counts describe the listed sessions — the payload carries no status
/// for overflowed or detached ones.
extension TerminalSessionAttributes.ContentState {
    var liveCount: Int { sessions.filter { $0.status == .live }.count }
    var startingCount: Int { sessions.filter { $0.status == .starting }.count }
    var failedCount: Int { sessions.filter { $0.status == .failed }.count }

    /// The frontmost session's shell — the one line of shell-adjacent data
    /// the app itself picked, so it can't be ugly.
    var activeShell: String? {
        guard let active = sessions.first(where: { $0.isActive }) else { return nil }
        return active.shell.isEmpty ? nil : active.shell
    }

    /// "5 live · 1 starting · 1 failed", skipping empty groups; nil when
    /// nothing is listed at all.
    var runningSummary: String? {
        var parts: [String] = []
        if liveCount > 0 {
            parts.append(String(
                localized: "\(liveCount) live",
                comment: "Sessions with a running shell"
            ))
        }
        if startingCount > 0 {
            parts.append(String(
                localized: "\(startingCount) starting",
                comment: "Sessions still spawning"
            ))
        }
        if failedCount > 0 {
            parts.append(String(
                localized: "\(failedCount) failed",
                comment: "Sessions whose transport gave up"
            ))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The one-line rendition for the island: the running summary with the
    /// detached count folded in, since there's no room for label pairs.
    var summaryLine: String? {
        var parts: [String] = []
        if let runningSummary { parts.append(runningSummary) }
        if detachedCount > 0 {
            parts.append(String(
                localized: "\(detachedCount) detached",
                comment: "Sessions running with no tab attached"
            ))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Previews

#if DEBUG

extension TerminalSessionAttributes {
    static let preview = TerminalSessionAttributes()
}

extension TerminalSessionAttributes.ContentState {
    /// The common case: a couple of tabs, one frontmost.
    static let typical = TerminalSessionAttributes.ContentState(
        sessions: [
            .init(
                id: "a",
                title: "make deb",
                directory: "~/Documents/GitHub/iGhostVT",
                shell: "zsh",
                number: 1,
                status: .live,
                isActive: true
            ),
            .init(
                id: "b",
                title: "",
                directory: "~",
                shell: "fish",
                number: 2,
                status: .live,
                isActive: false
            ),
        ],
        overflowCount: 0,
        detachedCount: 0
    )

    /// `typical`, a moment later — the same two sessions, a third one
    /// opening and one failed, more of them past the row cap. The overlap
    /// lets the canvas demonstrate the transition: the number rolls, the
    /// bar reapportions, the detached pair fades in.
    static let crowded = TerminalSessionAttributes.ContentState(
        sessions: [
            .init(
                id: "a",
                title: "make deb",
                directory: "~/Documents/GitHub/iGhostVT",
                shell: "zsh",
                number: 1,
                status: .live,
                isActive: false
            ),
            .init(
                id: "b",
                title: "",
                directory: "~",
                shell: "fish",
                number: 2,
                status: .failed,
                isActive: false
            ),
            .init(
                id: "c",
                title: "ssh build-host",
                directory: "",
                shell: "zsh",
                number: 3,
                status: .starting,
                isActive: true
            ),
        ],
        overflowCount: 2,
        detachedCount: 1
    )
}

#Preview("Lock Screen", as: .content, using: TerminalSessionAttributes.preview) {
    TerminalSessionActivityWidget()
} contentStates: {
    TerminalSessionAttributes.ContentState.typical
    TerminalSessionAttributes.ContentState.crowded
}

#endif
