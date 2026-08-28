//
//  LockableTerminalView.swift
//  iGhostVT
//

import GhosttyTerminal
import UIKit

/// The app's terminal view: `TerminalView` plus an interaction lock.
///
/// A locked tab freezes the *user*, never the program: output keeps
/// flowing, the surface keeps rendering, the session keeps running. The
/// blocking therefore lives here, at the view — refuse hit testing and
/// first responder and every input path is closed at once — instead of
/// being scattered across SwiftUI modifiers. Installed through
/// `TerminalViewState.makePlatformView` (see `TerminalTab`).
final class LockableTerminalView: TerminalView {
    /// When true the view refuses every interaction: touches never land
    /// (`hitTest` returns nil) and keyboard focus is refused and released,
    /// which closes the hardware-key path too.
    var isInteractionLocked = false {
        didSet {
            guard isInteractionLocked, isFirstResponder else { return }
            resignFirstResponder()
        }
    }

    /// Keyboard lock: a clean tap no longer raises or dismisses the
    /// software keyboard. The tap's click still reaches the program, and
    /// touches, scrolling, and hardware keys stay live.
    var isKeyboardTapLocked = false

    override var canBecomeFirstResponder: Bool {
        !isInteractionLocked && super.canBecomeFirstResponder
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        isInteractionLocked ? nil : super.hitTest(point, with: event)
    }

    #if !targetEnvironment(macCatalyst)
        // The library's tap path calls this after the tap's click has been
        // sent; only the keyboard raise/dismiss is ours to swallow. On
        // Catalyst there is no software keyboard and no such member.
        override func toggleSoftwareKeyboard() {
            guard !isKeyboardTapLocked else { return }
            super.toggleSoftwareKeyboard()
        }
    #endif
}
