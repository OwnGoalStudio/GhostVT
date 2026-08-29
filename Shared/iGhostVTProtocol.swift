import Foundation

/// Wire contract shared by the app and `ighostvtd`.
///
/// The daemon owns every terminal session: it is the only component allowed
/// to spawn a process, and it holds the PTY, the child, and the recent output
/// buffer. The app is a view onto that state — it may attach to a session,
/// send keystrokes, and resize, but it never forks or execs anything itself.
/// Sessions therefore outlive the app: relaunching reattaches to the daemon's
/// live shells instead of starting new ones.
enum iGhostVTProtocol {
    static let version: UInt64 = 1
    static let serviceName = "wiki.qaq.ighostvt.service"
    static let clientEntitlement = "wiki.qaq.ighostvt.client"

    /// Root-owned executables permitted to open a session. Written relative to
    /// the bootstrap's root and checked against the caller's real executable
    /// path, so a roothide jbroot or a rootless `/var/jb` prefix stays intact.
    static let clientPaths = [
        "/Applications/iGhostVT.app/iGhostVT",
    ]

    static let maximumMessageDataByteCount = 1 << 20
    static let maximumSessionsPerPeer = 32
    static let maximumCommandArgumentCount = 64

    /// Live sessions across every peer.
    ///
    /// The per-peer limit alone does not bound the daemon: sessions outlive
    /// the connection that opened them, so an app that opens its 32 and
    /// relaunches would leave the old ones behind and start counting from
    /// zero again. This is the ceiling that actually holds — worst case
    /// `maximumSessions × sessionReplayByteCount` of retained output, plus one
    /// shell each.
    static let maximumSessions = 64

    /// Output retained per session for replay when a client attaches. Enough
    /// for a screenful of a busy TUI plus scrollback context. Hard cap: the
    /// buffer is trimmed from the front on every append, so a session that
    /// prints forever still costs this much and no more.
    static let sessionReplayByteCount = 256 * 1024

    static let defaultColumns: UInt16 = 80
    static let defaultRows: UInt16 = 24
    static let maximumColumns: UInt16 = 2000
    static let maximumRows: UInt16 = 2000
}

/// Client-initiated requests. Each one gets exactly one reply.
enum iGhostVTOperation: UInt64, Sendable {
    case hello = 1
    case listSessions = 2
    case openSession = 3
    case attachSession = 4
    case detachSession = 5
    case write = 6
    case resize = 7
    case closeSession = 8
    case goodbye = 9
    /// Exit, if no session is held; `sessionBusy` otherwise. Sent by the app
    /// as it quits, after closing the tabs it decided to close and seeing
    /// them leave `listSessions`. Whether the exit sticks is launchd's call:
    /// the Mac's agent restarts only on a crash, the device daemon is kept
    /// alive regardless, so the app only asks on the Mac.
    case shutdown = 10
}

/// Daemon-initiated pushes on an attached connection. These carry no reply.
enum iGhostVTEvent: UInt64, Sendable {
    case output = 100
    case sessionExit = 101
    /// The foreground process on the session's terminal changed; carries
    /// its name (`processName`) and whether that process is the shell the
    /// session spawned (`foregroundIsShell`) — true at the prompt, false
    /// while a command runs. Also stated once in every open/attach reply,
    /// so a client knows the current state without waiting for a change.
    case processName = 102
}

enum iGhostVTReplyCode: Int64, Sendable {
    case success = 0
    case invalidRequest = 1
    case unsupportedVersion = 2
    case handshakeRequired = 3
    case sessionLimitReached = 4
    case unknownSession = 5
    case sessionBusy = 6
    case spawnFailed = 7
    case operationFailed = 8
}

enum iGhostVTWireKey {
    static let version = "v"
    static let operation = "op"
    static let event = "ev"
    static let code = "code"
    static let sessionID = "sid"
    static let sessions = "sessions"
    static let data = "data"
    static let columns = "cols"
    static let rows = "rows"
    static let command = "cmd"
    static let environment = "env"
    /// On `openSession`: a live session whose shell's current directory the
    /// new one should start in. The daemon reads that directory from the
    /// kernel itself — the app never names a path.
    static let inheritDirectoryFrom = "cwdsid"
    static let title = "title"
    static let isAttached = "attached"
    static let processName = "proc"
    /// Whether the foreground process group is the session's own shell,
    /// i.e. nothing is running in front of it.
    static let foregroundIsShell = "fgshell"
    static let exitCode = "exit"
    static let reason = "reason"
    /// Why a request failed, in words, when the reply code alone would lose
    /// the detail — the failing step and its `errno`, mainly.
    static let errorMessage = "err"
}

/// A reply code carrying the sentence the app should show.
///
/// The codes are a closed set the app can branch on; this adds the part only
/// the daemon knows — which shell it tried, which syscall refused, what the
/// system said — so a failed session can explain itself instead of showing
/// the same generic line for every cause.
struct iGhostVTFailure: Error, Equatable, Sendable {
    var code: iGhostVTReplyCode
    var message: String

    init(_ code: iGhostVTReplyCode, _ message: String) {
        self.code = code
        self.message = message
    }
}
