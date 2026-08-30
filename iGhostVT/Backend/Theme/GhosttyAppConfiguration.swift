import GhosttyTerminal

/// Runtime Ghostty config compiled into the generated overlay.
///
/// On Mac, CJK ranges are pinned to PingFang SC so CoreText never picks a
/// face at first sight (ghostty#9410). That is `font-codepoint-map` only —
/// a bare `font-family = PingFang SC` becomes the primary face when the
/// overlay has no earlier family, and PingFang is proportional, so every
/// cell is stretched (ghostty#12694). iOS already falls back to PingFang
/// stably; it does not need the map.
enum GhosttyAppConfiguration {
    static var terminal: TerminalConfiguration {
        #if targetEnvironment(macCatalyst)
            TerminalConfiguration {
                $0.withCustom("font-codepoint-map", "U+4E00-U+9FFF=PingFang SC")
                $0.withCustom("font-codepoint-map", "U+3400-U+4DBF=PingFang SC")
                $0.withCustom("font-codepoint-map", "U+F900-U+FAFF=PingFang SC")
                $0.withCustom("font-codepoint-map", "U+3000-U+303F=PingFang SC")
                $0.withCustom("font-codepoint-map", "U+FF00-U+FFEF=PingFang SC")
            }
        #else
            TerminalConfiguration()
        #endif
    }
}
