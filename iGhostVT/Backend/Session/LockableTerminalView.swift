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

    #if targetEnvironment(macCatalyst)
        /// Retains the drop delegate: `UIDropInteraction` holds its delegate
        /// weakly, and non-nil is also the flag that the swap already happened.
        private var macFileDrop: MacFileDropDelegate?

        /// Swaps the library's drop handling for the Mac's.
        ///
        /// The library's `dropInteraction(_:performDrop:)` is `public`, not
        /// `open`, so a subclass cannot override it — but it can be *called*,
        /// which is what makes replacing the whole interaction safe: everything
        /// this host does not want to change is forwarded straight back to it.
        /// The library installs its interaction from `setupPlatformInput()`
        /// during init, so by the time there is a window it is there to remove.
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, macFileDrop == nil else { return }
            for interaction in interactions where interaction is UIDropInteraction {
                removeInteraction(interaction)
            }
            let delegate = MacFileDropDelegate(terminal: self)
            macFileDrop = delegate
            addInteraction(UIDropInteraction(delegate: delegate))
        }
    #endif
}

#if targetEnvironment(macCatalyst)

    /// Dropping a file on a Mac pastes **the path it already has**.
    ///
    /// The library stages a copy first, and on iOS that is the only honest
    /// answer: a drop out of Files or Photos has no path the shell could open,
    /// so the terminal writes one. A Mac drag is the opposite case — the file
    /// is sitting in the filesystem the shell is already looking at, and it
    /// carries `public.file-url` saying exactly where. Pasting the path of a
    /// copy instead is wrong twice over: someone drags `report.pdf` off the
    /// Desktop to run `open` on it and gets a duplicate, which then silently
    /// rots 24 hours later when the staging sweep collects it.
    ///
    /// A Finder drag registers the file's data type *and* its URL, and the
    /// library looks at data first — so this has to come in ahead of it, not
    /// after. Drops that really do carry no path (Photos, a Mail attachment)
    /// find no URL here and are handed back to the library, where staging is
    /// still the right answer. So is every other part of the protocol: only
    /// `performDrop`, and only its file-URL half, behaves differently here.
    private final class MacFileDropDelegate: NSObject, UIDropInteractionDelegate {
        private weak var terminal: LockableTerminalView?

        init(terminal: LockableTerminalView) {
            self.terminal = terminal
        }

        func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
            terminal?.dropInteraction(interaction, canHandle: session) ?? false
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
            terminal?.dropInteraction(interaction, sessionDidUpdate: session) ?? UIDropProposal(operation: .cancel)
        }

        func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
            guard let terminal else { return }
            guard session.canLoadObjects(ofClass: NSURL.self) else {
                terminal.dropInteraction(interaction, performDrop: session)
                return
            }
            _ = session.loadObjects(ofClass: NSURL.self) { [weak terminal] objects in
                let urls = objects.compactMap { ($0 as? NSURL) as URL? }
                guard let terminal, !urls.isEmpty else { return }
                // A path is escaped for the prompt the user goes on typing at;
                // a web link has no path to escape and goes in whole.
                let text = urls
                    .map { $0.isFileURL ? Self.shellEscaped($0.path) : $0.absoluteString }
                    .joined(separator: " ")
                // The trailing space is the ergonomic half: it separates a
                // second dropped file from the first, and leaves the caret
                // ready for an argument instead of glued to the path.
                _ = terminal.paste(text: text + " ")
            }
        }

        /// Backslash-escapes what a POSIX shell would otherwise read as syntax.
        ///
        /// The character set is Ghostty's `Shell.escape`, mirrored here because
        /// the library keeps its own copy internal. Backslashes rather than
        /// quotes: this lands at a live prompt someone keeps editing, not in a
        /// command line being assembled.
        private static func shellEscaped(_ path: String) -> String {
            let sensitive: Set<Character> = [
                "\\", " ", "(", ")", "[", "]", "{", "}", "<", ">", "\"", "'", "`",
                "!", "#", "$", "&", ";", "|", "*", "?", "\t",
            ]
            var result = ""
            result.reserveCapacity(path.utf8.count)
            for character in path {
                if sensitive.contains(character) { result.append("\\") }
                result.append(character)
            }
            return result
        }
    }

#endif
