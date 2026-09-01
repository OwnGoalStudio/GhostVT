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
        ShareSheet.present(url, in: window)
    }
}
