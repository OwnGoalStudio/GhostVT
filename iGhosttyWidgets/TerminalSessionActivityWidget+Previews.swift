//
//  TerminalSessionActivityWidget+Previews.swift
//  iGhosttyWidgets
//
//  Xcode-canvas previews of the Dynamic Island; the lock screen preview and
//  the shared sample states live beside LockScreenView.
//
//  DEBUG-only: the #Preview(as:using:) machinery needs iOS 17, so the Debug
//  configuration targets 17.0 while Release stays at 16.2 for the devices
//  the package actually supports — this file must not compile there.
//

#if DEBUG

import ActivityKit
import SwiftUI
import WidgetKit

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
