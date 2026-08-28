//
//  LockableTerminalView.swift
//  iGhostVT
//

import GhosttyTerminal
import UIKit

/// The app's terminal view: `TerminalView` plus the two locks.
///
/// A locked tab freezes the *user*, never the program: output keeps
/// flowing, the surface keeps rendering, the session keeps running. The
/// blocking therefore lives here, at the view — refuse hit testing, first
/// responder, or the keyboard, and every path into the terminal is closed at
/// its end — instead of being scattered across SwiftUI modifiers that each
/// have to remember. Installed through `TerminalViewState.makePlatformView`
/// (see `TerminalTab`).
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

    /// Keyboard lock: the software keyboard stays down. Touches, scrolling,
    /// selection, and hardware keys stay live — only the on-screen keyboard
    /// is refused.
    ///
    /// Swallowing the tap toggle is not enough on its own: the library
    /// becomes first responder from several other places — the long-press
    /// selection menu, a pointer click, the host's own `requestFocus` after a
    /// sheet dismisses — and each of those brought the keyboard back up. So
    /// the lock is enforced where every one of those paths ends instead, at
    /// the input view.
    var isSoftwareKeyboardLocked = false {
        didSet {
            guard isSoftwareKeyboardLocked != oldValue else { return }
            // The iPad shortcuts bar is not part of `inputAccessoryView`, and
            // an empty keyboard leaves it (and its dictation button) floating
            // over the terminal, stealing 40pt of grid. Empty its groups for
            // as long as the lock lasts.
            inputAssistantItem.leadingBarButtonGroups = []
            inputAssistantItem.trailingBarButtonGroups = []
            guard isFirstResponder else { return }
            // Already first responder: swap the input views in place, so
            // locking drops the keyboard that is up and unlocking brings it
            // back without the user having to tap again.
            reloadInputViews()
        }
    }

    /// What the terminal offers UIKit as its keyboard while locked. An empty
    /// view keeps first-responder status — and with it the hardware key
    /// path — while leaving nothing to raise.
    private lazy var suppressedInputView = UIView(frame: .zero)

    override var canBecomeFirstResponder: Bool {
        !isInteractionLocked && super.canBecomeFirstResponder
    }

    override var inputView: UIView? {
        isSoftwareKeyboardLocked ? suppressedInputView : super.inputView
    }

    override var inputAccessoryView: UIView? {
        // The bar belongs to the keyboard; leaving it floating over a
        // keyboard that is not there reads as a half-open keyboard.
        isSoftwareKeyboardLocked ? nil : super.inputAccessoryView
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        isInteractionLocked ? nil : super.hitTest(point, with: event)
    }

    #if !targetEnvironment(macCatalyst)
        // The library's tap path calls this after the tap's click has been
        // sent; only the keyboard raise/dismiss is ours to swallow. On
        // Catalyst there is no software keyboard and no such member.
        override func toggleSoftwareKeyboard() {
            guard !isSoftwareKeyboardLocked else { return }
            super.toggleSoftwareKeyboard()
        }
    #endif
}
