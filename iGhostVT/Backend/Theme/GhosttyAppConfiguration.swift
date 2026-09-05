import GhosttyTerminal

/// Runtime Ghostty config compiled into the generated overlay.
///
/// On Mac, CJK ranges are pinned to PingFang SC so CoreText never picks a
/// face at first sight (ghostty#9410). That is `font-codepoint-map` only —
/// a bare `font-family = PingFang SC` becomes the primary face when the
/// overlay has no earlier family, and PingFang is proportional, so every
/// cell is stretched (ghostty#12694). iOS already falls back to PingFang
/// stably; it does not need the map.
///
/// The font size is written here as well as into the surface options. The
/// library's base config carries its own `font-size` (10 on every iOS-family
/// build, Catalyst included), and the surface option only overrides it at
/// the surface's birth: every later config reload — the colour scheme the
/// view reports on mount, a theme change — reapplies the *file* to the
/// surface, and a file without the preference reset the first terminal to
/// the library's size. A later line wins in ghostty, so this one does.
enum GhosttyAppConfiguration {
    static var terminal: TerminalConfiguration {
        TerminalConfiguration { builder in
            builder.withFontSize(TerminalFontSize.preferred)
            // Said outright rather than left to the default: a connected
            // terminal whose shell has yet to print (half a minute for the
            // first shell after a reboot) has only the cursor to show it
            // is alive, and a blinking one reads as waiting where a still
            // one reads as dead. A program that sets DECSCUSR still wins.
            builder.withCursorStyleBlink(true)
            // The grid rarely divides the pane exactly, and the remainder is
            // painted as padding. A program that paints its own background
            // (a TUI on the primary screen, vim) then sits in a box of the
            // theme's colour with a lip of a different one along two edges.
            // `extend` paints that lip with the nearest cell's background;
            // ghostty's own heuristic keeps it off a row with any
            // default-background cell, a prompt row, or a powerline row.
            builder.withCustom("window-padding-color", "extend")
            #if targetEnvironment(macCatalyst)
                builder.withCustom("font-codepoint-map", "U+4E00-U+9FFF=PingFang SC")
                builder.withCustom("font-codepoint-map", "U+3400-U+4DBF=PingFang SC")
                builder.withCustom("font-codepoint-map", "U+F900-U+FAFF=PingFang SC")
                builder.withCustom("font-codepoint-map", "U+3000-U+303F=PingFang SC")
                builder.withCustom("font-codepoint-map", "U+FF00-U+FFEF=PingFang SC")
            #endif
        }
    }

    /// The configuration file a terminal opened now would run, as ghostty
    /// reads it: the library's base, this overlay, then the theme for
    /// `colorScheme` — the same order the library's renderer joins them in,
    /// so what Settings shows is what a surface gets. Purely informational;
    /// the library writes the real file itself when a tab is made.
    @MainActor
    static func renderedConfig(for colorScheme: TerminalColorScheme) -> String {
        let theme = AppTheme.shared.terminalTheme
        let themeConfiguration = colorScheme == .dark ? theme.dark : theme.light
        return [
            TerminalConfiguration.default.rendered,
            terminal.rendered,
            themeConfiguration.rendered,
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n") + "\n"
    }
}
