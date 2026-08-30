//
//  SessionIntents.swift
//  iGhostVT
//

import AppIntents
import Foundation

// The headless intents: each opens one connection to the daemon, asks its
// question, and closes it — the CLI's commands as Shortcuts actions. None
// attaches, so a session a tab is showing keeps its tab throughout, and
// none needs the app in front. They are the `ighostvt-cli` verbs: `list`,
// `new`, `send`, `capture`, `kill`, plus the compositions a script would
// otherwise build out of them.

@available(iOS 16.0, macCatalyst 16.0, *)
struct ListSessionsIntent: AppIntent {
    static let title: LocalizedStringResource = "List Terminal Sessions"
    static let description = IntentDescription(
        "Returns every terminal session in iGhostVT, whether or not a tab is showing it.",
        categoryName: "Sessions"
    )

    func perform() async throws -> some IntentResult & ReturnsValue<[SessionEntity]> {
        let sessions = try await ShortcutDaemonClient.withConnection { client in
            try await client.listSessions().map(SessionEntity.init)
        }
        return .result(value: sessions)
    }
}

@available(iOS 16.0, macCatalyst 16.0, *)
struct NewSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "New Terminal Session"
    static let description = IntentDescription(
        "Starts a shell in the background and returns the session. Show it in a tab or send text to it later.",
        categoryName: "Sessions"
    )

    @Parameter(
        title: "Program",
        description: "A program to run instead of the shell, with its arguments. Leave empty for the default shell."
    )
    var program: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Start a new terminal session") {
            \.$program
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<SessionEntity> {
        let arguments = ShellWords.split(program ?? "")
        let session = try await ShortcutDaemonClient.withConnection { client in
            let id = try await client.openSession(command: arguments, inheritDirectoryFrom: nil)
            return try await client.session(id)
        }
        return .result(value: SessionEntity(session))
    }
}

@available(iOS 16.0, macCatalyst 16.0, *)
struct SendTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Text to Terminal"
    static let description = IntentDescription(
        "Types text into a terminal session, as if entered on its keyboard.",
        categoryName: "Input"
    )
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Session")
    var session: SessionEntity

    @Parameter(title: "Text")
    var text: String

    @Parameter(title: "Press Return", default: true)
    var pressReturn: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$text) to \(\.$session)") {
            \.$pressReturn
        }
    }

    func perform() async throws -> some IntentResult {
        let bytes = Array(text.utf8) + (pressReturn ? [0x0D] : [])
        try await ShortcutDaemonClient.withConnection { client in
            try await client.inject(bytes, into: session.daemonID)
        }
        return .result()
    }
}

@available(iOS 16.0, macCatalyst 16.0, *)
struct SendKeyIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Key to Terminal"
    static let description = IntentDescription(
        "Presses one key in a terminal session — Return, Escape, an arrow, or a control combination such as Control-C.",
        categoryName: "Input"
    )

    @Parameter(title: "Session")
    var session: SessionEntity

    @Parameter(title: "Key", default: .enter)
    var key: TerminalKey

    static var parameterSummary: some ParameterSummary {
        Summary("Press \(\.$key) in \(\.$session)")
    }

    func perform() async throws -> some IntentResult {
        try await ShortcutDaemonClient.withConnection { client in
            try await client.inject(key.bytes, into: session.daemonID)
        }
        return .result()
    }
}

@available(iOS 16.0, macCatalyst 16.0, *)
struct GetScreenTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Terminal Screen Text"
    static let description = IntentDescription(
        "Returns what a terminal session is showing, as plain text. Can also include the scrollback iGhostVT still keeps.",
        categoryName: "Output"
    )
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Session")
    var session: SessionEntity

    @Parameter(title: "Include Scrollback", default: false)
    var includeScrollback: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Get the screen text of \(\.$session)") {
            \.$includeScrollback
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let snapshot = try await ShortcutDaemonClient.withConnection { client in
            try await client.snapshot(session.daemonID)
        }
        return .result(value: snapshot.text(fullTranscript: includeScrollback))
    }
}

@available(iOS 16.0, macCatalyst 16.0, *)
struct GetSessionDirectoryIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Terminal Directory"
    static let description = IntentDescription(
        "Returns the directory a terminal session's shell is in.",
        categoryName: "Output"
    )

    @Parameter(title: "Session")
    var session: SessionEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Get the current directory of \(\.$session)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let row = try await ShortcutDaemonClient.withConnection { client in
            try await client.session(session.daemonID)
        }
        return .result(value: row.currentDirectory ?? "")
    }
}

@available(iOS 16.0, macCatalyst 16.0, *)
struct IsSessionBusyIntent: AppIntent {
    static let title: LocalizedStringResource = "Is Terminal Busy"
    static let description = IntentDescription(
        "Checks whether a program is running in a terminal session. A session waiting at its shell prompt is not busy.",
        categoryName: "Output"
    )

    @Parameter(title: "Session")
    var session: SessionEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Is \(\.$session) running a program")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let row = try await ShortcutDaemonClient.withConnection { client in
            try await client.session(session.daemonID)
        }
        // An unknown state reads as busy, the way the app's close
        // confirmation reads it.
        return .result(value: row.foregroundIsShell != true)
    }
}

@available(iOS 16.0, macCatalyst 16.0, *)
struct WaitForPromptIntent: AppIntent {
    static let title: LocalizedStringResource = "Wait for Terminal Prompt"
    static let description = IntentDescription(
        "Waits until the session's shell is back at its prompt, or until the time limit passes.",
        categoryName: "Output"
    )

    @Parameter(title: "Session")
    var session: SessionEntity

    @Parameter(title: "Time Limit (seconds)", default: 20, inclusiveRange: (1, 60))
    var timeout: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Wait for \(\.$session) to return to its prompt") {
            \.$timeout
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let ready = try await ShortcutDaemonClient.withConnection { client in
            try await client.waitForPrompt(session.daemonID, timeout: TimeInterval(timeout)) != nil
        }
        return .result(value: ready)
    }
}

@available(iOS 16.0, macCatalyst 16.0, *)
struct KillSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "End Terminal Session"
    static let description = IntentDescription(
        "Ends a terminal session and the program running in it. Any tab showing the session closes.",
        categoryName: "Sessions"
    )

    @Parameter(title: "Session")
    var session: SessionEntity

    static var parameterSummary: some ParameterSummary {
        Summary("End \(\.$session)")
    }

    func perform() async throws -> some IntentResult {
        try await ShortcutDaemonClient.withConnection { client in
            try await client.closeSession(session.daemonID)
        }
        return .result()
    }
}

/// The action people actually want from Siri: type a command, wait for the
/// prompt to come back, hand over what it printed.
@available(iOS 16.0, macCatalyst 16.0, *)
struct RunCommandIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Terminal Command"
    static let description = IntentDescription(
        "Types a command into a terminal session, waits for the shell to return to its prompt, and returns the output. With no session, a new shell is started for the command and ended afterwards.",
        categoryName: "Sessions"
    )
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Command Line")
    var command: String

    @Parameter(title: "Session", description: "Leave empty to run in a new shell.")
    var session: SessionEntity?

    @Parameter(title: "Time Limit (seconds)", default: 20, inclusiveRange: (1, 60))
    var timeout: Int

    @Parameter(
        title: "Keep New Session",
        description: "When the command ran in a new shell, leave that shell running instead of ending it.",
        default: false
    )
    var keepNewSession: Bool

    static var parameterSummary: some ParameterSummary {
        When(\.$session, .hasAnyValue) {
            Summary("Run \(\.$command) in \(\.$session)") {
                \.$timeout
            }
        } otherwise: {
            Summary("Run \(\.$command) in a new shell") {
                \.$timeout
                \.$keepNewSession
            }
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        let output = try await ShortcutDaemonClient.withConnection { client in
            let sessionID: UInt64
            let isNew: Bool
            if let session {
                sessionID = session.daemonID
                isNew = false
            } else {
                sessionID = try await client.openSession(command: [], inheritDirectoryFrom: nil)
                isNew = true
            }
            do {
                if isNew {
                    // The new shell has to reach its prompt before it can
                    // take the command — after a reboot that alone takes a
                    // while.
                    guard try await client.waitForPrompt(sessionID, timeout: deadline.timeIntervalSinceNow) != nil else {
                        throw ShortcutError.commandTimedOut
                    }
                }
                let output = try await Self.run(command, in: sessionID, client: client, deadline: deadline)
                if isNew, !keepNewSession {
                    try? await client.closeSession(sessionID)
                }
                return output
            } catch {
                if isNew, !keepNewSession {
                    try? await client.closeSession(sessionID)
                }
                throw error
            }
        }
        return .result(value: output)
    }

    /// Types the command and polls until the shell is back at its prompt
    /// with something new on the screen.
    private static func run(
        _ command: String,
        in sessionID: UInt64,
        client: ShortcutDaemonClient,
        deadline: Date
    ) async throws -> String {
        let before = try await client.snapshot(sessionID).text(fullTranscript: true)
        try await client.inject(Array(command.utf8) + [0x0D], into: sessionID)
        // Give the shell a beat to take the line: a check made before it
        // even echoed the command would see the old prompt and call that
        // done.
        try await Task.sleep(nanoseconds: 150_000_000)
        while true {
            let row = try await client.session(sessionID)
            let after = try await client.snapshot(sessionID).text(fullTranscript: true)
            if row.foregroundIsShell == true, after != before {
                return CommandOutput.newLines(before: before, after: after)
            }
            if Date() >= deadline {
                throw ShortcutError.commandTimedOut
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }
}

/// What a command printed, as the difference between two transcripts. The
/// replay buffer is trimmed from the front, so the earlier transcript is
/// not always a prefix of the later one; when it is not, the whole later
/// screen is the honest answer.
enum CommandOutput {
    static func newLines(before: String, after: String) -> String {
        let old = trimmed(before.split(separator: "\n", omittingEmptySubsequences: false))
        let new = trimmed(after.split(separator: "\n", omittingEmptySubsequences: false))
        // The last line of `before` is the prompt the command was typed on;
        // it is rewritten with the command, so everything above it is what
        // both transcripts share.
        let shared = old.dropLast()
        guard new.count > shared.count, new.prefix(shared.count).elementsEqual(shared) else {
            return new.joined(separator: "\n")
        }
        // Past the shared part: the echoed command line, the output, and
        // the new prompt. The first and the last are not output.
        var lines = new.dropFirst(shared.count)
        lines = lines.dropFirst()
        if !lines.isEmpty {
            lines = lines.dropLast()
        }
        return trimmed(lines).joined(separator: "\n")
    }

    private static func trimmed<C: BidirectionalCollection>(_ lines: C) -> ArraySlice<C.Element>
        where C.Element: StringProtocol
    {
        var slice = ArraySlice(lines)
        while let last = slice.last, last.allSatisfy(\.isWhitespace) {
            slice = slice.dropLast()
        }
        return slice
    }
}

/// A program line split into argv the way a shell would, minus the shell:
/// whitespace separates, single and double quotes group, a backslash
/// escapes the next character. Nothing expands.
enum ShellWords {
    static func split(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var hasWord = false
        var quote: Character?
        var escaped = false
        for character in line {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\", quote != "'" {
                escaped = true
                hasWord = true
                continue
            }
            if let open = quote {
                if character == open {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                hasWord = true
                continue
            }
            if character.isWhitespace {
                if hasWord {
                    words.append(current)
                    current = ""
                    hasWord = false
                }
                continue
            }
            current.append(character)
            hasWord = true
        }
        if hasWord {
            words.append(current)
        }
        return words
    }
}
