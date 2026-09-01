import Foundation

/// Infers a title from the command line the user typed, for the sessions
/// where nothing better is available.
///
/// A shell with Ghostty's integration reports its own title over OSC 2 and
/// this never gets a say — `TerminalSessionStore` only consults it while the
/// surface's title is empty, which is exactly the case where the shell has no
/// integration loaded (no `ZDOTDIR` injection, a shell we don't inject into,
/// or a bare `sh`).
///
/// The rule is deliberately narrow: only a line typed with ordinary printable
/// keys, terminated by Return, becomes a title. Everything that makes the
/// keystrokes stop matching what is on screen — an escape sequence (arrows,
/// history), a completion `Tab`, a line-editing control — abandons the line.
/// The store then checks the candidate against the viewport before using it,
/// which is what keeps a password out of the tab bar: with echo off the
/// typed bytes are nowhere on screen, so nothing is accepted.
final class CommandTitleTracker: @unchecked Sendable {
    /// Fired on Return with a line worth offering. Never called for a line
    /// this tracker gave up on.
    var onCommand: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    private var buffer: [UInt8] = []
    /// The keystrokes no longer reconstruct the line on screen — the shell
    /// edited it behind our back (completion, history recall, kill ring).
    private var abandoned = false

    /// A command line longer than this is a paste or a here-doc, not a title.
    private static let maximumLength = 256

    func consume(_ data: Data) {
        // Only the last plausible line a chunk completes is offered: every
        // offer overwrites the one before, and each costs the store a
        // viewport read on the main thread — a paste of thousands of short
        // lines arrives as one chunk and used to queue one read per line.
        var completed: String?
        lock.lock()
        for byte in data {
            switch byte {
            case 0x0D, 0x0A: // Return / Enter
                if !abandoned, !buffer.isEmpty,
                   let line = String(bytes: buffer, encoding: .utf8),
                   Self.isPlausibleCommand(line)
                {
                    completed = line
                }
                buffer.removeAll(keepingCapacity: true)
                abandoned = false

            case 0x7F, 0x08: // Delete / Backspace
                if buffer.isEmpty {
                    break
                }
                // Drop a whole UTF-8 scalar: the shell erases a character,
                // not a byte, and half a scalar would poison the decode.
                // The buffer can hold nothing but continuation bytes (the
                // length cap once cut a paste mid-scalar and the scalar's
                // tail was appended after the reset), so the lead byte is
                // popped, never `removeLast` on what may be empty.
                while let last = buffer.last, last & 0xC0 == 0x80 {
                    buffer.removeLast()
                }
                _ = buffer.popLast()

            case 0x00 ... 0x1F: // ESC, Tab, ^C, ^U, ^W, ^R, …
                buffer.removeAll(keepingCapacity: true)
                abandoned = true

            default:
                // An abandoned line collects nothing more: Return resets it
                // regardless, and a scalar the cap cut in half would
                // otherwise leave its continuation bytes behind on their own.
                if abandoned {
                    break
                }
                buffer.append(byte)
                if buffer.count > Self.maximumLength {
                    buffer.removeAll(keepingCapacity: true)
                    abandoned = true
                }
            }
        }
        lock.unlock()

        if let completed, let onCommand {
            onCommand(completed)
        }
    }

    func reset() {
        lock.lock()
        buffer.removeAll(keepingCapacity: true)
        abandoned = false
        lock.unlock()
    }

    /// Whether a completed line is worth showing as a title at all.
    ///
    /// The first character carries most of the signal: a shell command starts
    /// with a word, a path, or `~`, while the lines a full-screen program
    /// collects (`:wq`, `/search`) start with punctuation and would otherwise
    /// retitle the tab with vim's ex-command history.
    static func isPlausibleCommand(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        guard first.isLetter || first.isNumber
            || first == "/" || first == "." || first == "~" || first == "_"
        else { return false }
        return !line.contains { $0.isNewline }
    }
}
