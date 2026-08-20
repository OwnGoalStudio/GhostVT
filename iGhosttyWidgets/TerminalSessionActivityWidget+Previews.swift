//
//  TerminalSessionActivityWidget+Previews.swift
//  iGhosttyWidgets
//
//  Xcode-canvas previews of the Live Activity. The sample states live here,
//  private, because nothing but the canvas renders fabricated sessions.
//
//  DEBUG-only: the #Preview(as:using:) machinery needs iOS 17, so the Debug
//  configuration targets 17.0 while Release stays at 16.2 for the devices
//  the package actually supports — this file must not compile there.
//

#if DEBUG

import ActivityKit
import SwiftUI
import WidgetKit

private extension TerminalSessionAttributes {
    static let preview = TerminalSessionAttributes()
}

private extension TerminalSessionAttributes.ContentState {
    /// The common case: a couple of tabs, one frontmost.
    static let typical = TerminalSessionAttributes.ContentState(
        sessions: [
            .init(
                id: "a",
                title: "make deb",
                directory: "~/Documents/GitHub/iGhostty",
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

    /// Every row shape at once: starting, failed, unnamed, plus the footer's
    /// overflow and detached counts.
    static let crowded = TerminalSessionAttributes.ContentState(
        sessions: [
            .init(
                id: "a",
                title: "ssh build-host",
                directory: "",
                shell: "zsh",
                number: 1,
                status: .starting,
                isActive: true
            ),
            .init(
                id: "b",
                title: "",
                directory: "/var/jb/usr/share/ighostty",
                shell: "",
                number: 2,
                status: .live,
                isActive: false
            ),
            .init(
                id: "c",
                title: "htop",
                directory: "~",
                shell: "sh",
                number: 3,
                status: .failed,
                isActive: false
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

#Preview("Island Expanded", as: .dynamicIsland(.expanded), using: TerminalSessionAttributes.preview) {
    TerminalSessionActivityWidget()
} contentStates: {
    TerminalSessionAttributes.ContentState.typical
    TerminalSessionAttributes.ContentState.crowded
}

#Preview("Island Compact", as: .dynamicIsland(.compact), using: TerminalSessionAttributes.preview) {
    TerminalSessionActivityWidget()
} contentStates: {
    TerminalSessionAttributes.ContentState.typical
}

#Preview("Island Minimal", as: .dynamicIsland(.minimal), using: TerminalSessionAttributes.preview) {
    TerminalSessionActivityWidget()
} contentStates: {
    TerminalSessionAttributes.ContentState.typical
}

#endif
