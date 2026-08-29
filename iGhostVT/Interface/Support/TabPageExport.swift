//
//  TabPageExport.swift
//  iGhostVT
//

import UIKit

/// The page — what the terminal is showing right now, trailing padding
/// stripped — as text, and the share sheet that exports it. Reached from
/// the tab's context menu and from File ▸ Export Text…, so it lives apart
/// from either.
@MainActor
enum TabPageExport {
    /// The viewport's rows, each stripped of the trailing padding a grid
    /// carries, without the blank region under the last printed row.
    static func pageText(of tab: TerminalTab) -> String {
        tab.snapshotPreview()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { row in
                var row = row
                while let last = row.last, last == " " || last == "\t" {
                    row = row.dropLast()
                }
                return String(row)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func exportText(of tab: TerminalTab, in window: UIWindow?) {
        let text = pageText(of: tab)
        let base = tab.displayTitle
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(base.isEmpty ? "Terminal" : base).txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return
        }
        // After a menu's dismissal animation: presenting into it leaves a
        // dead sheet (the switcher's settings entry hit the same race). A
        // key command pays the same wait; it is too short to notice.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            presentShareSheet(for: url, in: window)
        }
    }

    private static func presentShareSheet(for url: URL, in window: UIWindow?) {
        guard let window, var top = window.rootViewController else { return }
        while let presented = top.presentedViewController {
            top = presented
        }
        let controller = UIActivityViewController(
            activityItems: [url],
            applicationActivities: nil
        )
        // iPad and the Mac require an anchor or the presentation crashes;
        // the menu that triggered this is gone, so anchor to the window.
        if let popover = controller.popoverPresentationController {
            popover.sourceView = window
            popover.sourceRect = CGRect(
                x: window.bounds.midX,
                y: window.bounds.midY,
                width: 1,
                height: 1
            )
            popover.permittedArrowDirections = []
        }
        top.present(controller, animated: true)
    }
}
