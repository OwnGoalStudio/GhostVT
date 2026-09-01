import Foundation

/// Turns a session's replay bytes back into the text the terminal is
/// showing.
///
/// The daemon keeps raw PTY output, not a grid — a screen is what a
/// terminal emulator *makes* of that stream — so `capture` has to replay
/// it. libghostty could do it exactly, but only through a live surface with
/// a renderer attached, which a command-line tool has no business creating.
/// This is the subset that decides what text lands where: the cursor, the
/// scroll region, erasing, insert and delete, the alternate screen, and
/// character width. Colour and every other attribute is parsed and dropped,
/// because the output is text.
///
/// Known limits, all deliberate: no reflow (the buffer is replayed at the
/// session's current size, so output written when the window was another
/// shape lands where a resize without reflow would put it), DEC line
/// drawing is left as its ASCII bytes, and a stream that begins mid-escape
/// resyncs at the first byte that cannot continue the sequence — the replay
/// buffer is trimmed from the front, so its first bytes are routinely a
/// fragment.
final class ScreenRenderer {
    /// The right-hand half of a double-width character. Never printed; it
    /// keeps a wide glyph's second column occupied so overwrites and
    /// cursor arithmetic stay honest.
    private static let spacer: Character = "\u{0}"
    private static let scrollbackLineLimit = 20000

    private let columns: Int
    private let rows: Int
    private var screen: [[Character]]
    private var scrollback: [[Character]] = []
    private var cursorRow = 0
    private var cursorColumn = 0
    private var savedCursor = (row: 0, column: 0)
    private var scrollTop: Int
    private var scrollBottom: Int
    private var autoWrap = true
    /// xterm's deferred wrap: writing in the last column leaves the cursor
    /// there, and the *next* character is what moves to the new line. Losing
    /// this puts a spurious blank line after every full-width line.
    private var wrapPending = false
    private var saved: (screen: [[Character]], cursor: (row: Int, column: Int), usesCursor: Bool)?

    private enum State {
        case ground
        case escape
        case csi
        /// OSC — ends at BEL or ST.
        case operatingSystemCommand
        /// DCS/SOS/PM/APC — ends at ST.
        case ignoredString
        /// Inside a string, having just seen ESC: `\` ends it.
        case stringEscape
        /// The byte after `ESC (` and friends.
        case charset
    }

    private var state: State = .ground
    private var controlSequence: [UInt8] = []
    private var pendingScalar: [UInt8] = []
    private var pendingScalarLength = 0

    init(columns: UInt16, rows: UInt16) {
        self.columns = max(1, Int(columns))
        self.rows = max(1, Int(rows))
        screen = Array(repeating: Array(repeating: " ", count: self.columns), count: self.rows)
        scrollTop = 0
        scrollBottom = self.rows - 1
    }

    // MARK: - Input

    func feed(_ data: Data) {
        for byte in data { consume(byte) }
    }

    func feed(_ text: String) {
        feed(Data(text.utf8))
    }

    private func consume(_ byte: UInt8) {
        switch state {
        case .ground:
            ground(byte)
        case .escape:
            escape(byte)
        case .csi:
            // Parameters and intermediates, then one final byte.
            if byte >= 0x40, byte <= 0x7E {
                let final = byte
                let sequence = controlSequence
                controlSequence = []
                state = .ground
                applyControlSequence(sequence, final: final)
            } else if byte >= 0x20, byte <= 0x3F {
                if controlSequence.count < 64 { controlSequence.append(byte) }
            } else {
                // A control byte inside a sequence: the sequence is
                // abandoned and the byte acts, which is how a truncated
                // replay resyncs.
                controlSequence = []
                state = .ground
                ground(byte)
            }
        case .operatingSystemCommand:
            if byte == 0x07 {
                state = .ground
            } else if byte == 0x1B {
                state = .stringEscape
            }
        case .ignoredString:
            if byte == 0x1B { state = .stringEscape }
        case .stringEscape:
            // ESC \ terminates; anything else was part of the string, and
            // an ESC that starts something new is taken as such.
            if byte == 0x5C {
                state = .ground
            } else if byte == 0x1B {
                state = .stringEscape
            } else {
                state = .ignoredString
            }
        case .charset:
            state = .ground
        }
    }

    private func ground(_ byte: UInt8) {
        if pendingScalarLength > 0 {
            if byte & 0xC0 == 0x80 {
                pendingScalar.append(byte)
                if pendingScalar.count == pendingScalarLength {
                    emitPendingScalar()
                }
                return
            }
            // Not a continuation: the sequence was truncated by the replay
            // trim or is malformed. Drop it and read this byte fresh.
            pendingScalar = []
            pendingScalarLength = 0
        }

        switch byte {
        case 0x00, 0x07:
            return
        case 0x08:
            cursorColumn = max(0, cursorColumn - 1)
            wrapPending = false
        case 0x09:
            let next = ((cursorColumn / 8) + 1) * 8
            cursorColumn = min(columns - 1, next)
            wrapPending = false
        case 0x0A, 0x0B, 0x0C:
            index()
        case 0x0D:
            cursorColumn = 0
            wrapPending = false
        case 0x1B:
            state = .escape
        case 0x7F:
            return
        default:
            if byte < 0x20 { return }
            if byte < 0x80 {
                place(Character(UnicodeScalar(byte)), width: 1)
                return
            }
            if byte & 0xE0 == 0xC0 {
                pendingScalarLength = 2
            } else if byte & 0xF0 == 0xE0 {
                pendingScalarLength = 3
            } else if byte & 0xF8 == 0xF0 {
                pendingScalarLength = 4
            } else {
                return
            }
            pendingScalar = [byte]
        }
    }

    private func emitPendingScalar() {
        let bytes = pendingScalar
        pendingScalar = []
        pendingScalarLength = 0
        let text = String(decoding: bytes, as: UTF8.self)
        guard let scalar = text.unicodeScalars.first, scalar != "\u{FFFD}" else { return }
        let width = Self.width(of: scalar)
        if width == 0 {
            attachCombining(Character(scalar))
            return
        }
        place(Character(scalar), width: width)
    }

    private func escape(_ byte: UInt8) {
        state = .ground
        switch byte {
        case 0x5B: // [
            controlSequence = []
            state = .csi
        case 0x5D: // ]
            state = .operatingSystemCommand
        case 0x50, 0x58, 0x5E, 0x5F: // P X ^ _
            state = .ignoredString
        case 0x28, 0x29, 0x2A, 0x2B: // ( ) * +
            state = .charset
        case 0x37: // 7
            savedCursor = (cursorRow, cursorColumn)
        case 0x38: // 8
            cursorRow = min(rows - 1, savedCursor.row)
            cursorColumn = min(columns - 1, savedCursor.column)
            wrapPending = false
        case 0x44: // D
            index()
        case 0x45: // E
            cursorColumn = 0
            index()
        case 0x4D: // M
            reverseIndex()
        case 0x63: // c
            reset()
        default:
            return
        }
    }

    // MARK: - Control sequences

    private func applyControlSequence(_ sequence: [UInt8], final: UInt8) {
        var isPrivate = false
        var body = sequence
        if let first = body.first, first == 0x3F { // ?
            isPrivate = true
            body.removeFirst()
        }
        // Intermediates are not used by anything here; drop them so a
        // parameter list still parses. Every parameter is clamped as it
        // is read: the sequence cap admits the nineteen digits of Int.max,
        // and adding that to a cursor position traps, while a grid of
        // UInt16 cells never needs more than this.
        body.removeAll { $0 >= 0x20 && $0 <= 0x2F }
        let parameters = String(decoding: body, as: UTF8.self)
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { min(Int($0) ?? 0, 65535) }
        func parameter(_ index: Int, default fallback: Int = 1) -> Int {
            guard index < parameters.count else { return fallback }
            let value = parameters[index]
            return value == 0 ? fallback : value
        }
        func rawParameter(_ index: Int) -> Int {
            index < parameters.count ? parameters[index] : 0
        }

        if isPrivate {
            switch final {
            case 0x68: setPrivateMode(parameters, enabled: true)   // h
            case 0x6C: setPrivateMode(parameters, enabled: false)  // l
            default: return
            }
            return
        }

        switch final {
        case 0x41: // A
            cursorRow = max(cursorRow >= scrollTop ? scrollTop : 0, cursorRow - parameter(0))
            wrapPending = false
        case 0x42: // B
            cursorRow = min(cursorRow <= scrollBottom ? scrollBottom : rows - 1, cursorRow + parameter(0))
            wrapPending = false
        case 0x43: // C
            cursorColumn = min(columns - 1, cursorColumn + parameter(0))
            wrapPending = false
        case 0x44: // D
            cursorColumn = max(0, cursorColumn - parameter(0))
            wrapPending = false
        case 0x45: // E
            cursorRow = min(rows - 1, cursorRow + parameter(0))
            cursorColumn = 0
            wrapPending = false
        case 0x46: // F
            cursorRow = max(0, cursorRow - parameter(0))
            cursorColumn = 0
            wrapPending = false
        case 0x47, 0x60: // G, `
            cursorColumn = clampColumn(parameter(0) - 1)
            wrapPending = false
        case 0x64: // d
            cursorRow = clampRow(parameter(0) - 1)
            wrapPending = false
        case 0x48, 0x66: // H, f
            cursorRow = clampRow(parameter(0) - 1)
            cursorColumn = clampColumn(parameter(1) - 1)
            wrapPending = false
        case 0x4A: // J
            eraseInDisplay(rawParameter(0))
        case 0x4B: // K
            eraseInLine(rawParameter(0))
        case 0x4C: // L
            insertLines(parameter(0))
        case 0x4D: // M
            deleteLines(parameter(0))
        case 0x40: // @
            insertCharacters(parameter(0))
        case 0x50: // P
            deleteCharacters(parameter(0))
        case 0x58: // X
            eraseCharacters(parameter(0))
        case 0x53: // S
            scrollUp(parameter(0))
        case 0x54: // T
            scrollDown(parameter(0))
        case 0x72: // r
            let top = clampRow(parameter(0) - 1)
            let bottom = clampRow(parameters.count > 1 ? parameter(1, default: rows) - 1 : rows - 1)
            if top < bottom {
                scrollTop = top
                scrollBottom = bottom
            } else {
                scrollTop = 0
                scrollBottom = rows - 1
            }
            cursorRow = scrollTop
            cursorColumn = 0
            wrapPending = false
        case 0x73: // s
            savedCursor = (cursorRow, cursorColumn)
        case 0x75: // u
            cursorRow = clampRow(savedCursor.row)
            cursorColumn = clampColumn(savedCursor.column)
            wrapPending = false
        default:
            return
        }
    }

    private func setPrivateMode(_ parameters: [Int], enabled: Bool) {
        for mode in parameters {
            switch mode {
            case 7:
                autoWrap = enabled
            case 47, 1047, 1049:
                setAlternateScreen(enabled, restoresCursor: mode == 1049)
            default:
                continue
            }
        }
    }

    /// The alternate screen is what full-screen programs draw on; leaving it
    /// puts back the shell's screen underneath, which is why a `capture`
    /// after `vim` quits shows the prompt again and not vim's last frame.
    private func setAlternateScreen(_ enabled: Bool, restoresCursor: Bool) {
        if enabled {
            guard saved == nil else { return }
            saved = (screen, (cursorRow, cursorColumn), restoresCursor)
            screen = Array(repeating: Array(repeating: " ", count: columns), count: rows)
            cursorRow = 0
            cursorColumn = 0
            wrapPending = false
        } else {
            guard let saved else { return }
            screen = saved.screen
            if saved.usesCursor {
                cursorRow = clampRow(saved.cursor.row)
                cursorColumn = clampColumn(saved.cursor.column)
            }
            self.saved = nil
            wrapPending = false
        }
    }

    private func reset() {
        screen = Array(repeating: Array(repeating: " ", count: columns), count: rows)
        cursorRow = 0
        cursorColumn = 0
        savedCursor = (0, 0)
        scrollTop = 0
        scrollBottom = rows - 1
        autoWrap = true
        wrapPending = false
        saved = nil
    }

    // MARK: - Grid operations

    private func clampRow(_ row: Int) -> Int { min(max(0, row), rows - 1) }
    private func clampColumn(_ column: Int) -> Int { min(max(0, column), columns - 1) }

    private func blankRow() -> [Character] {
        Array(repeating: " ", count: columns)
    }

    private func place(_ character: Character, width: Int) {
        if wrapPending, autoWrap {
            cursorColumn = 0
            index()
            wrapPending = false
        }
        if width == 2, cursorColumn == columns - 1 {
            guard autoWrap else { return }
            cursorColumn = 0
            index()
        }
        screen[cursorRow][cursorColumn] = character
        if width == 2, cursorColumn + 1 < columns {
            screen[cursorRow][cursorColumn + 1] = Self.spacer
        }
        cursorColumn += width
        if cursorColumn >= columns {
            cursorColumn = columns - 1
            wrapPending = true
        }
    }

    /// A combining mark belongs to the character already written, not to a
    /// cell of its own.
    private func attachCombining(_ mark: Character) {
        var column = cursorColumn
        if !wrapPending { column -= 1 }
        while column >= 0, screen[cursorRow][column] == Self.spacer { column -= 1 }
        guard column >= 0 else { return }
        // Not every pair joins: a format scalar such as U+200B breaks the
        // cluster, and so does a C1 control or U+00AD sitting in the cell.
        // `Character` traps on two clusters in Debug and stores them both in
        // Release, so a mark that will not attach is dropped instead.
        let joined = String(screen[cursorRow][column]) + String(mark)
        guard joined.count == 1 else { return }
        screen[cursorRow][column] = Character(joined)
    }

    private func index() {
        if cursorRow == scrollBottom {
            scrollUp(1)
        } else if cursorRow < rows - 1 {
            cursorRow += 1
        }
        wrapPending = false
    }

    private func reverseIndex() {
        if cursorRow == scrollTop {
            scrollDown(1)
        } else if cursorRow > 0 {
            cursorRow -= 1
        }
        wrapPending = false
    }

    private func scrollUp(_ count: Int) {
        // Scrolling by more than the region's height leaves the same blank
        // region as scrolling by exactly its height, and xterm clamps the
        // count the same way; without the clamp each step is a remove and
        // an insert across the grid, and a large CSI S parameter is a
        // hang for `capture` and the Shortcuts snapshot alike.
        for _ in 0 ..< min(max(1, count), scrollBottom - scrollTop + 1) {
            let departing = screen[scrollTop]
            // Only the primary screen's top line becomes history: a line
            // scrolled out of a region, or off the alternate screen, is
            // gone in a real terminal too.
            if saved == nil, scrollTop == 0 {
                scrollback.append(departing)
                if scrollback.count > Self.scrollbackLineLimit {
                    scrollback.removeFirst(scrollback.count - Self.scrollbackLineLimit)
                }
            }
            screen.remove(at: scrollTop)
            screen.insert(blankRow(), at: scrollBottom)
        }
    }

    private func scrollDown(_ count: Int) {
        // The same clamp as scrollUp, for the same reason: CSI T past the
        // region's height blanks it just as fully.
        for _ in 0 ..< min(max(1, count), scrollBottom - scrollTop + 1) {
            screen.remove(at: scrollBottom)
            screen.insert(blankRow(), at: scrollTop)
        }
    }

    private func eraseInDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseInLine(0)
            for row in (cursorRow + 1) ..< rows { screen[row] = blankRow() }
        case 1:
            eraseInLine(1)
            for row in 0 ..< cursorRow { screen[row] = blankRow() }
        case 2, 3:
            for row in 0 ..< rows { screen[row] = blankRow() }
            if mode == 3 { scrollback.removeAll() }
        default:
            return
        }
        wrapPending = false
    }

    private func eraseInLine(_ mode: Int) {
        switch mode {
        case 0:
            for column in cursorColumn ..< columns { screen[cursorRow][column] = " " }
        case 1:
            for column in 0 ... min(cursorColumn, columns - 1) { screen[cursorRow][column] = " " }
        case 2:
            screen[cursorRow] = blankRow()
        default:
            return
        }
        wrapPending = false
    }

    private func insertLines(_ count: Int) {
        guard cursorRow >= scrollTop, cursorRow <= scrollBottom else { return }
        // Once every row from the cursor to the region's bottom is blank,
        // another pass changes nothing, so the loop stops there however
        // large the parameter was.
        for _ in 0 ..< min(count, scrollBottom - cursorRow + 1) {
            screen.remove(at: scrollBottom)
            screen.insert(blankRow(), at: cursorRow)
        }
        cursorColumn = 0
        wrapPending = false
    }

    private func deleteLines(_ count: Int) {
        guard cursorRow >= scrollTop, cursorRow <= scrollBottom else { return }
        for _ in 0 ..< min(count, scrollBottom - cursorRow + 1) {
            screen.remove(at: cursorRow)
            screen.insert(blankRow(), at: scrollBottom)
        }
        cursorColumn = 0
        wrapPending = false
    }

    private func insertCharacters(_ count: Int) {
        // Once every cell from the cursor to the row's end is blank, another
        // pass changes nothing, so the loop stops there however large the
        // parameter was.
        for _ in 0 ..< min(count, columns - cursorColumn) {
            screen[cursorRow].insert(" ", at: cursorColumn)
            screen[cursorRow].removeLast()
        }
        wrapPending = false
    }

    private func deleteCharacters(_ count: Int) {
        // The remove and the append keep the row at `columns`, so a guard on
        // the row's length never fires; the loop is bounded by the cells
        // left in the row instead, as the insert above is.
        for _ in 0 ..< min(count, columns - cursorColumn) {
            screen[cursorRow].remove(at: cursorColumn)
            screen[cursorRow].append(" ")
        }
        wrapPending = false
    }

    private func eraseCharacters(_ count: Int) {
        let end = min(columns, cursorColumn + count)
        guard cursorColumn < end else { return }
        for column in cursorColumn ..< end { screen[cursorRow][column] = " " }
        wrapPending = false
    }

    // MARK: - Output

    /// What the screen is showing, trailing padding removed — the same
    /// shape the app's own "copy page as text" produces.
    func screenText() -> String {
        Self.text(of: screen)
    }

    /// Everything the buffer covers: the lines that scrolled off the top,
    /// then the screen.
    func transcriptText() -> String {
        Self.text(of: scrollback + screen)
    }

    private static func text(of grid: [[Character]]) -> String {
        var lines = grid.map { row -> String in
            var line = String(row.filter { $0 != spacer })
            while let last = line.last, last == " " || last == "\t" {
                line.removeLast()
            }
            return line
        }
        while let last = lines.last, last.isEmpty {
            lines.removeLast()
        }
        while let first = lines.first, first.isEmpty {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Character width

    /// Columns a scalar occupies: 0 for a combining mark, 2 for the East
    /// Asian wide and fullwidth ranges and the common emoji blocks, 1
    /// otherwise. Enough to keep a CJK or emoji line's cells aligned; the
    /// full Unicode width tables are libghostty's business, not a text
    /// dump's.
    static func width(of scalar: Unicode.Scalar) -> Int {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format:
            if scalar.value == 0x00AD { return 1 }
            return 0
        default:
            break
        }
        let value = scalar.value
        for range in wideRanges where range.contains(value) {
            return 2
        }
        return 1
    }

    private static let wideRanges: [ClosedRange<UInt32>] = [
        0x1100 ... 0x115F,
        0x2E80 ... 0x303E,
        0x3041 ... 0x33FF,
        0x3400 ... 0x4DBF,
        0x4E00 ... 0x9FFF,
        0xA000 ... 0xA4CF,
        0xA960 ... 0xA97F,
        0xAC00 ... 0xD7A3,
        0xF900 ... 0xFAFF,
        0xFE10 ... 0xFE19,
        0xFE30 ... 0xFE6F,
        0xFF00 ... 0xFF60,
        0xFFE0 ... 0xFFE6,
        0x1F300 ... 0x1F64F,
        0x1F680 ... 0x1F6FF,
        0x1F900 ... 0x1F9FF,
        0x20000 ... 0x2FFFD,
        0x30000 ... 0x3FFFD,
    ]
}
