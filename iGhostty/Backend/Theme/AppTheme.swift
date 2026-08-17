//
//  AppTheme.swift
//  iGhostty
//

import GhosttyTerminal
import GhosttyTheme
import SwiftUI

/// The one owner of the terminal theme preference. Persists a light and a
/// dark selection from the Ghostty theme catalog, derives the terminal theme
/// and the chrome colors from them, and is observed by every view that
/// paints chrome — so the whole window (including safe areas) follows the
/// terminal's background.
@MainActor
final class AppTheme: ObservableObject {
    static let shared = AppTheme()

    struct Selection: Equatable {
        var lightName: String?
        var darkName: String?
    }

    @Published var selection: Selection {
        didSet {
            UserDefaults.standard.set(selection.lightName, forKey: Self.lightKey)
            UserDefaults.standard.set(selection.darkName, forKey: Self.darkKey)
        }
    }

    private static let lightKey = "Theme.light"
    private static let darkKey = "Theme.dark"

    /// Built-in fallbacks matching `TerminalTheme.default`.
    private static let defaultLightBackground = "F7F7F7"
    private static let defaultDarkBackground = "212121"

    private init() {
        selection = Selection(
            lightName: UserDefaults.standard.string(forKey: Self.lightKey),
            darkName: UserDefaults.standard.string(forKey: Self.darkKey)
        )
    }

    private var lightDefinition: GhosttyThemeDefinition? {
        selection.lightName.flatMap { GhosttyThemeCatalog.theme(named: $0) }
    }

    private var darkDefinition: GhosttyThemeDefinition? {
        selection.darkName.flatMap { GhosttyThemeCatalog.theme(named: $0) }
    }

    var terminalTheme: TerminalTheme {
        TerminalTheme(
            light: lightDefinition?.toTerminalConfiguration() ?? .alabaster,
            dark: darkDefinition?.toTerminalConfiguration() ?? .afterglow
        )
    }

    func background(for scheme: ColorScheme) -> Color {
        let hex = scheme == .dark
            ? darkDefinition?.background ?? Self.defaultDarkBackground
            : lightDefinition?.background ?? Self.defaultLightBackground
        return Color(hex: hex)
    }

    func hairline(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.12)
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = UInt32(hex, radix: 16) ?? 0
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
