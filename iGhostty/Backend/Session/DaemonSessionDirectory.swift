//
//  DaemonSessionDirectory.swift
//  iGhostty
//

import Foundation

/// The app's window onto the daemon's session registry. The daemon is the
/// only book of record — the app persists nothing about sessions and asks
/// (`listSessions`) whenever it needs the truth: cold-launch reattach, the
/// Live Activity's detached count, anything else that used to guess from a
/// UserDefaults ledger.
@MainActor
final class DaemonSessionDirectory {
    static let shared = DaemonSessionDirectory()

    /// Last answer the daemon gave. Purely a cache of the last `refresh()`;
    /// never persisted.
    private(set) var sessions: [XPCDaemonTransport.SessionSummary] = []

    private var hasClaimedResumable = false

    private init() {}

    /// The daemon sessions no peer is attached to, for the first window of a
    /// cold launch to adopt. Exactly one caller per process gets them; every
    /// later window starts fresh, mirroring the old ledger's claim semantics
    /// without the ledger.
    func claimResumable(completion: @escaping @MainActor @Sendable ([UInt64]) -> Void) {
        guard !hasClaimedResumable else {
            completion([])
            return
        }
        hasClaimedResumable = true
        XPCDaemonTransport.listSessions { rows in
            Task { @MainActor in
                let rows = rows ?? []
                self.sessions = rows
                completion(rows.filter { !$0.isAttached }.map(\.id))
            }
        }
    }

    /// Re-ask the daemon and notify the Live Activity when the answer moved.
    func refresh() {
        XPCDaemonTransport.listSessions { rows in
            guard let rows else { return }
            Task { @MainActor in
                guard rows != self.sessions else { return }
                self.sessions = rows
                SessionActivityController.shared.refresh()
            }
        }
    }
}
