import Darwin
import Foundation

// The CLI's screen model. `capture` is only as truthful as this file, and
// it is the one part of the CLI with no daemon in the loop — so it is
// tested here on its own, with byte streams standing in for a shell.

var failures: [String] = []

func check(_ condition: Bool, _ description: String) {
    if condition {
        print("  ok   \(description)")
    } else {
        print("  FAIL \(description)")
        failures.append(description)
    }
}

/// Renders `stream` on a grid of the given size and returns the screen.
func render(
    _ stream: String,
    columns: UInt16 = 20,
    rows: UInt16 = 5,
    full: Bool = false
) -> String {
    let renderer = ScreenRenderer(columns: columns, rows: rows)
    renderer.feed(stream)
    return full ? renderer.transcriptText() : renderer.screenText()
}

/// Raw bytes, for streams a Swift literal cannot express — a UTF-8
/// sequence cut in half by the replay buffer's front trim, say.
func renderBytes(_ bytes: [UInt8], columns: UInt16 = 20, rows: UInt16 = 5) -> String {
    let renderer = ScreenRenderer(columns: columns, rows: rows)
    renderer.feed(Data(bytes))
    return renderer.screenText()
}

let escape = "\u{1B}"

print("screen renderer: text and wrapping")
check(render("hello") == "hello", "plain text lands on the screen")
check(render("hello\r\nworld") == "hello\nworld", "CR LF starts a line")
check(render("hello\nworld") == "hello\n     world", "a bare LF does not return the carriage")
check(
    render("0123456789abcdefghijklmno", columns: 10, rows: 5) == "0123456789\nabcdefghij\nklmno",
    "text wraps at the last column"
)
check(
    render("0123456789\r\nnext", columns: 10, rows: 5) == "0123456789\nnext",
    "a line that exactly fills the width leaves no blank line behind"
)
check(render("a\u{8}b") == "b", "backspace moves back over a cell")
check(render("a\tb", columns: 20) == "a       b", "tab advances to the next stop")

print("screen renderer: scrolling and history")
check(
    render("one\r\ntwo\r\nthree\r\nfour\r\nfive\r\nsix", columns: 20, rows: 3)
        == "four\nfive\nsix",
    "output scrolls the screen"
)
check(
    render("one\r\ntwo\r\nthree\r\nfour\r\nfive\r\nsix", columns: 20, rows: 3, full: true)
        == "one\ntwo\nthree\nfour\nfive\nsix",
    "and the lines that scrolled off are the transcript"
)

print("screen renderer: cursor and erasing")
check(render("hello\(escape)[2J\(escape)[Hbye") == "bye", "erase-display and home clear the screen")
check(render("hello\(escape)[1;1Hj") == "jello", "cursor position overwrites in place")
check(render("hello\(escape)[3Gx") == "hexlo", "column address moves within the line")
check(render("hello\(escape)[1;3H\(escape)[K") == "he", "erase-to-end-of-line clears the rest")
check(render("hello\(escape)[1;3H\(escape)[1K") == "   lo", "erase-to-start clears up to the cursor")
check(render("hello\(escape)[1;3H\(escape)[2K") == "", "erase-line clears all of it")
check(render("hello\(escape)[1;3H\(escape)[2P") == "heo", "delete-character pulls the line left")
check(render("hello\(escape)[1;3H\(escape)[2@") == "he  llo", "insert-character pushes it right")
check(render("hello\(escape)[1;3H\(escape)[2X") == "he  o", "erase-character blanks in place")
check(render("hello\(escape)[s\(escape)[2;1Hthere\(escape)[u!") == "hello!\nthere", "the cursor saves and restores")
check(render("hello\(escape)7\(escape)[2;1Hthere\(escape)8!") == "hello!\nthere", "and so does the ESC 7 / ESC 8 pair")

print("screen renderer: lines and regions")
check(
    render("one\r\ntwo\r\nthree\(escape)[1;1H\(escape)[L", columns: 20, rows: 3) == "one\ntwo",
    "insert-line pushes the screen down, off the bottom"
)
check(
    render("one\r\ntwo\r\nthree\(escape)[1;1H\(escape)[M", columns: 20, rows: 4) == "two\nthree",
    "delete-line pulls it up"
)
check(
    render("\(escape)[2;3r\(escape)[2;1Ha\r\nb\r\nc", columns: 20, rows: 4) == "b\nc",
    "output scrolls inside a scroll region, leaving the rows outside it alone"
)
check(
    render("one\r\ntwo\r\nthree\(escape)[2;3r\(escape)[2;1H\(escape)M", columns: 20, rows: 3)
        == "one\n\ntwo",
    "reverse index scrolls the region down"
)

print("screen renderer: alternate screen")
check(
    render("shell\(escape)[?1049hfullscreen\(escape)[?1049l") == "shell",
    "leaving the alternate screen puts the primary back"
)
check(
    render("shell\(escape)[?1049hfullscreen") == "fullscreen",
    "and while it is up, it is what is shown"
)
check(
    render("one\r\ntwo\r\nthree\r\nfour\(escape)[?1049hx\(escape)[?1049l", columns: 20, rows: 2, full: true)
        == "one\ntwo\nthree\nfour",
    "the alternate screen does not add to the transcript"
)

print("screen renderer: escapes that carry no text")
check(render("\(escape)]0;a title\u{7}hello") == "hello", "an OSC ended by BEL is swallowed")
check(render("\(escape)]7;file:///tmp\(escape)\\hello") == "hello", "an OSC ended by ST is swallowed")
check(render("\(escape)]133;A\u{7}$ \(escape)]133;B\u{7}ls") == "$ ls", "shell-integration marks leave only the text")
check(render("\(escape)[31mred\(escape)[0m") == "red", "colour is parsed and dropped")
check(render("\(escape)Pq#0;2;0;0;0\(escape)\\hello") == "hello", "a device-control string is swallowed")
check(render("\(escape)(0hello") == "hello", "a charset selection consumes only its own byte")

print("screen renderer: broken and partial input")
check(render("2;5Hhello") == "2;5Hhello", "a stream starting mid-sequence prints what is left of it")
check(render("\(escape)[1;2") == "", "a sequence cut off at the end leaves nothing behind")
check(render("ab\(escape)[3\r\ncd") == "ab\ncd", "a control byte inside a sequence abandons it and acts")
check(renderBytes([0x63, 0x61, 0x66, 0xC3]) == "caf", "a UTF-8 scalar cut short at the end is dropped")
check(renderBytes([0xA9, 0x63, 0x61, 0x66]) == "caf", "a stream starting on a continuation byte resyncs")

print("screen renderer: character width")
check(render("\u{4F60}\u{597D}", columns: 4, rows: 2) == "\u{4F60}\u{597D}", "CJK text renders")
check(
    render("\u{4F60}\u{597D}ab", columns: 4, rows: 2) == "\u{4F60}\u{597D}\nab",
    "a wide character occupies two columns"
)
check(render("e\u{301}") == "e\u{301}", "a combining mark joins the character before it")

if failures.isEmpty {
    print("cli renderer: all checks passed")
    exit(EXIT_SUCCESS)
} else {
    print("cli renderer: \(failures.count) failure(s)")
    for failure in failures { print("  - \(failure)") }
    exit(EXIT_FAILURE)
}
