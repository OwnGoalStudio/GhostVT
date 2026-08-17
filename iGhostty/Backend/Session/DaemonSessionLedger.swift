//
//  DaemonSessionLedger.swift
//  iGhostty
//

import Foundation

/// App-wide record of daemon session IDs this app has opened and not killed.
/// Because the daemon keeps shells alive across app launches, the ledger is
/// what lets a cold launch reattach: the first window claims the persisted
/// IDs and recreates one tab per live session.
@MainActor
final class DaemonSessionLedger {
    static let shared = DaemonSessionLedger()

    private static let key = "Daemon.sessionIDs"
    private var hasClaimedPersisted = false

    private init() {}

    /// The persisted IDs, exactly once per process — the first window restores
    /// them; later windows start fresh.
    func claimPersisted() -> [UInt64] {
        guard !hasClaimedPersisted else { return [] }
        hasClaimedPersisted = true
        return currentIDs()
    }

    /// Running daemon sessions, as far as this app knows.
    var count: Int { currentIDs().count }

    func add(_ id: UInt64) {
        var ids = currentIDs()
        guard !ids.contains(id) else { return }
        ids.append(id)
        persist(ids)
        SessionActivityController.shared.refresh()
    }

    func remove(_ id: UInt64) {
        persist(currentIDs().filter { $0 != id })
        SessionActivityController.shared.refresh()
    }

    private func currentIDs() -> [UInt64] {
        (UserDefaults.standard.stringArray(forKey: Self.key) ?? [])
            .compactMap { UInt64($0) }
    }

    private func persist(_ ids: [UInt64]) {
        UserDefaults.standard.set(ids.map(String.init), forKey: Self.key)
    }
}
