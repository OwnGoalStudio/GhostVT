//
//  StatusDot.swift
//  iGhosttyWidgets
//

import SwiftUI

/// One session's status as a color, with a halo when its tab is frontmost.
struct StatusDot: View {
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

/// One dot per session in the expanded island's trailing region — a glance
/// tells you whether they are all up without reading the list.
struct StatusDots: View {
    let sessions: [TerminalSessionAttributes.Session]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(sessions.prefix(5)) { session in
                StatusDot(status: session.status, isActive: session.isActive, diameter: 6)
            }
        }
    }
}
