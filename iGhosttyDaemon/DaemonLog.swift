import os

/// The daemon's voice on the device (`log stream --process ighosttyd`).
///
/// Interpolations are marked public deliberately: nothing here carries user
/// content beyond session ids, pids, and executable paths, and a redacted
/// log is useless for the on-device debugging this exists for — the daemon
/// is otherwise a black box behind launchd.
enum DaemonLog {
    static let server = Logger(subsystem: "wiki.qaq.ighosttyd", category: "server")
    static let sessions = Logger(subsystem: "wiki.qaq.ighosttyd", category: "sessions")
}
