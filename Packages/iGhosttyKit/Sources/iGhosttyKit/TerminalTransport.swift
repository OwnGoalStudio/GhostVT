import Foundation

/// Where the bytes on the wire come from and go to.
///
/// The terminal surface itself is host-managed (libghostty's in-memory
/// backend); a transport is the other half of that contract — it carries the
/// byte stream to whatever produces it. Today that is the daemon transport
/// over XPC; an SSH channel implements the same protocol later without
/// touching the UI or session layers.
public protocol TerminalTransport: AnyObject {
    /// Single event stream. Delivered on an arbitrary transport-owned queue;
    /// hop to the main actor before touching UI state.
    var onEvent: (@Sendable (TerminalTransportEvent) -> Void)? { get set }

    var endpointDescription: String { get }

    func connect()

    /// Bytes typed into (or pasted into) the terminal.
    func send(_ data: Data)

    /// The terminal grid changed size. The daemon transport sends a `resize`;
    /// an SSH transport maps it to a window-change request.
    func updateViewport(columns: Int, rows: Int)

    func disconnect()
}

public enum TerminalTransportEvent: Sendable {
    case state(TerminalTransportState)
    case received(Data)
}

public enum TerminalTransportState: Sendable, Equatable {
    case connecting
    case connected
    /// The link died without the session ending — the endpoint may still
    /// hold the session, so a reconnect can reattach and resume. Distinct
    /// from `disconnected`, which is final: the session ended or the
    /// connection was refused, and only the user can ask for another.
    case interrupted(reason: String?)
    case disconnected(reason: String?)
}
