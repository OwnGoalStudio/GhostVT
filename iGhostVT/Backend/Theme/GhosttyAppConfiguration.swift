import GhosttyTerminal

/// Runtime Ghostty config compiled into the generated overlay. CJK ranges
/// are pinned so CoreText never picks a face at first sight (ghostty#9410).
/// Theme colours stack on top of this; they do not replace these lines.
enum GhosttyAppConfiguration {
    static var terminal: TerminalConfiguration {
        TerminalConfiguration {
            $0.withFontFamily("PingFang SC")
            $0.withCustom("font-codepoint-map", "U+4E00-U+9FFF=PingFang SC")
            $0.withCustom("font-codepoint-map", "U+3400-U+4DBF=PingFang SC")
            $0.withCustom("font-codepoint-map", "U+F900-U+FAFF=PingFang SC")
            $0.withCustom("font-codepoint-map", "U+3000-U+303F=PingFang SC")
            $0.withCustom("font-codepoint-map", "U+FF00-U+FFEF=PingFang SC")
        }
    }
}
