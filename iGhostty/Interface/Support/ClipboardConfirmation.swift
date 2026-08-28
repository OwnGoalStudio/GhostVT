import GhosttyTerminal
import SwiftUI
import UIKit

/// The question Ghostty asks before a protected clipboard operation: a
/// program reading the clipboard (OSC 52, `clipboard-read = ask`), a
/// program changing it when writes are set to ask, or a paste that paste
/// protection flagged — line breaks going to a program without bracketed
/// paste, which would run them as commands. Without an answer libghostty
/// denies a program's request silently, which is how a tool's "paste from
/// clipboard" used to do nothing at all.
///
/// Attached once, at the window root, like `CloseTabConfirmation`: the
/// request lives on the `TabManager` (which installs every tab's hook, so
/// none is missed), and the alert is a presented `AlertViewController` that
/// lands above whatever the window is showing.
struct ClipboardConfirmation: ViewModifier {
    @ObservedObject var tabManager: TabManager
    @State private var window: UIWindow?
    @State private var presented: AlertViewController?

    func body(content: Content) -> some View {
        content
            .background(WindowReader(window: $window))
            .onReceive(tabManager.$clipboardRequest) { request in
                present(request)
            }
            // A request raised before the window was read waits for it.
            .onChange(of: window == nil) { _ in
                present(tabManager.clipboardRequest)
            }
    }

    private func present(_ request: TerminalClipboardConfirmationRequest?) {
        guard let request, let window, presented == nil else { return }
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
        tabManager.finishClipboardRequest()
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
