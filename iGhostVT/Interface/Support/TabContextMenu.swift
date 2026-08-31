//
//  TabContextMenu.swift
//  iGhostVT
//

import GhosttyTerminal
import SwiftUI
import UIKit

/// The context menu shared by every presentation of a tab — the strip's
/// chips, the title capsule, the sidebar rows, and the switcher cards.
///
/// Copy and export read the viewport ("the page", see `TabPageExport`):
/// what the terminal is showing right now, trailing padding stripped. Copy
/// as Image prefers the surface's real pixels and falls back to drawing the
/// text for a tab whose surface is not currently rendering.
struct TabContextMenu: View {
    @ObservedObject var tab: TerminalTab
    let tabManager: TabManager
    let window: UIWindow?

    var body: some View {
        Button(action: copyText) {
            Label("Copy Text", systemImage: "doc.on.doc")
        }
        Button(action: copyImage) {
            Label("Copy as Image", systemImage: "photo.on.rectangle")
        }
        Button(action: exportText) {
            Label("Export Text…", systemImage: "square.and.arrow.up")
        }
        Divider()
        lockControls
        Divider()
        Button(role: .destructive, action: { tabManager.requestClose(tab) }) {
            Label("Close Tab", systemImage: "trash")
        }
    }

    /// Checkmarked toggles where the menu system renders them (iOS 16);
    /// state-named buttons before that, because a pre-16 menu shows no
    /// checkmark and a static "Lock Tab" would read as unlocked forever.
    /// The two are one choice: `TerminalTab.lock` holds at most one of
    /// them, so turning on the other lock switches, and turning off the one
    /// that is on clears it.
    ///
    /// One control per builder, on purpose: two toggles inside one
    /// `#available` branch make a `TupleContent`, whose `View` conformance
    /// the visionOS SDK dates to visionOS 26 with no back-deployment, and
    /// the app's floor there is visionOS 1. A single child per branch never
    /// forms the tuple.
    @ViewBuilder
    private var lockControls: some View {
        tabLockControl
        // Not on the Mac: there is no software keyboard to lock, and the
        // empty-inputView trick deliberately lets hardware keys through —
        // which is every key a Mac has, so the lock read as broken there.
        #if !targetEnvironment(macCatalyst)
            keyboardLockControl
        #endif
    }

    @ViewBuilder
    private var tabLockControl: some View {
        if #available(iOS 16.0, *) {
            Toggle(isOn: $tab.isLocked) {
                Label("Lock Tab", systemImage: "lock")
            }
        } else {
            if tab.isLocked {
                Button(action: { tab.isLocked = false }) {
                    Label("Unlock Tab", systemImage: "lock.open")
                }
            } else {
                Button(action: { tab.isLocked = true }) {
                    Label("Lock Tab", systemImage: "lock")
                }
            }
        }
    }

    #if !targetEnvironment(macCatalyst)
    @ViewBuilder
    private var keyboardLockControl: some View {
        if #available(iOS 16.0, *) {
            Toggle(isOn: $tab.isKeyboardLocked) {
                Label("Lock Keyboard", systemImage: "keyboard")
            }
        } else {
            if tab.isKeyboardLocked {
                Button(action: { tab.isKeyboardLocked = false }) {
                    Label("Unlock Keyboard", systemImage: "keyboard")
                }
            } else {
                Button(action: { tab.isKeyboardLocked = true }) {
                    Label("Lock Keyboard", systemImage: "keyboard")
                }
            }
        }
    }
    #endif

    // MARK: - The page as text

    private var pageText: String {
        TabPageExport.pageText(of: tab)
    }

    private func copyText() {
        UIPasteboard.general.string = pageText
    }

    // MARK: - The page as an image

    private func copyImage() {
        guard let image = surfaceImage() ?? renderedTextImage() else { return }
        UIPasteboard.general.image = image
    }

    /// The surface's real pixels — only while it is rendering. A background
    /// tab's surface is paused (`isSurfaceVisible == false`) and its last
    /// frame cannot be trusted to exist; the text fallback covers it.
    private func surfaceImage() -> UIImage? {
        guard tab.terminal.isSurfaceVisible else { return nil }
        return tab.terminal.attachedPlatformView?.snapshotImage()
    }

    /// The page text drawn in a monospaced face on the system background —
    /// deterministic, works for any tab in any presentation context.
    private func renderedTextImage() -> UIImage? {
        let text = pageText
        guard !text.isEmpty else { return nil }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: UIColor.label,
        ]
        let padding: CGFloat = 16
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: 4096, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: attributes,
            context: nil
        )
        let size = CGSize(
            width: ceil(bounds.width) + padding * 2,
            height: ceil(bounds.height) + padding * 2
        )
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.systemBackground.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            (text as NSString).draw(
                at: CGPoint(x: padding, y: padding),
                withAttributes: attributes
            )
        }
    }

    // MARK: - Export

    private func exportText() {
        TabPageExport.exportText(of: tab, in: window)
    }
}

/// New Tab / New Window, then the active tab's own menu. The iPad strip
/// and the compact bar both open this from their trailing ⋯.
struct TabOverflowMenuContent: View {
    @ObservedObject var tabManager: TabManager
    let window: UIWindow?

    var body: some View {
        Button(action: { tabManager.newTab() }) {
            Label("New Tab", systemImage: "plus")
        }
        Button(action: { TerminalWindow.requestNewWindow() }) {
            Label("New Window", systemImage: "macwindow.badge.plus")
        }
        if let tab = tabManager.activeTab {
            Divider()
            TabContextMenu(tab: tab, tabManager: tabManager, window: window)
        }
    }
}
