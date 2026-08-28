import GhosttyTerminal
import SwiftUI
import UIKit

/// The question Ghostty asks before a protected clipboard operation: a
/// program reading the clipboard (OSC 52, `clipboard-read = ask`), a
/// program changing it when writes are set to ask, or a paste that paste
/// protection flagged — line breaks going to a program without bracketed
/// paste, which would run them as commands. Without an answer libghostty
/// denies every one of these silently, which is how a tool's "paste from
/// clipboard" used to do nothing at all.
///
/// Attached once, at the window root, like `CloseTabConfirmation`: the alert
/// is a presented `AlertViewController`, so it lands above whatever the
/// window is showing. Requests queue behind an open alert rather than
/// replacing it — each one is answered exactly once.
struct ClipboardConfirmation: ViewModifier {
    @ObservedObject var tabManager: TabManager
    @State private var window: UIWindow?
    @State private var pending: [TerminalClipboardConfirmationRequest] = []
    @State private var presented: AlertViewController?

    func body(content: Content) -> some View {
        content
            .background(WindowReader(window: $window))
            .onAppear(perform: bindTabHooks)
            .onChange(of: tabManager.tabs.count) { _ in bindTabHooks() }
    }

    /// Re-bound whenever the tab set changes, so a tab created anywhere
    /// (strip, switcher, shortcut) gets the hook.
    private func bindTabHooks() {
        for tab in tabManager.tabs {
            tab.terminal.onClipboardConfirmationRequest = { request in
                pending.append(request)
                presentNextIfIdle()
            }
        }
    }

    private func presentNextIfIdle() {
        guard presented == nil, let window, !pending.isEmpty else { return }
        let request = pending.removeFirst()
        let alert = AlertViewController(
            title: Self.title(for: request.kind),
            message: Self.message(for: request),
            actions: [
                AlertAction("Deny") {
                    request.respond(allow: false)
                    finish()
                },
                AlertAction("Allow", kind: .accent) {
                    request.respond(allow: true)
                    finish()
                },
            ]
        )
        presented = alert
        alert.present(in: window)
    }

    private func finish() {
        presented = nil
        presentNextIfIdle()
    }

    private static func title(for kind: TerminalClipboardRequestKind) -> String.LocalizationValue {
        switch kind {
        case .osc52Read: "Allow Clipboard Access?"
        case .osc52Write: "Allow Clipboard Change?"
        case .paste: "Paste Multiple Lines?"
        }
    }

    private static func message(for request: TerminalClipboardConfirmationRequest) -> String.LocalizationValue {
        let preview = Self.preview(of: request.contents)
        switch request.kind {
        case .osc52Read:
            return "A program in this terminal wants to read the clipboard: \(preview)"
        case .osc52Write:
            return "A program in this terminal wants to replace the clipboard with: \(preview)"
        case .paste:
            return "This text contains line breaks or control characters the program may run as commands: \(preview)"
        }
    }

    /// The first line or so of what is at stake, short enough for a card.
    private static func preview(of contents: String) -> String {
        let flattened = contents
            .replacingOccurrences(of: "\r\n", with: " ⏎ ")
            .replacingOccurrences(of: "\n", with: " ⏎ ")
            .replacingOccurrences(of: "\r", with: " ⏎ ")
        let limit = 120
        guard flattened.count > limit else { return "“\(flattened)”" }
        return "“\(flattened.prefix(limit))…”"
    }
}

extension View {
    func clipboardConfirmation(_ tabManager: TabManager) -> some View {
        modifier(ClipboardConfirmation(tabManager: tabManager))
    }
}
