//
//  StatusDot.swift
//  iGhosttyWidgets
//

import SwiftUI

/// One session's status as a color.
struct StatusDot: View {
    let status: TerminalSessionAttributes.Session.Status

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
    }

    private var color: Color {
        switch status {
        case .starting: return Palette.starting
        case .live: return Palette.accent
        case .failed: return Palette.failed
        }
    }
}
