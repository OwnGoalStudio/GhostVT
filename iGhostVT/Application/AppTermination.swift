//
//  AppTermination.swift
//  iGhostVT
//

import UIKit

/// The one way the app ends itself on the Mac: AppKit's `terminate:`, so
/// `applicationWillTerminate` runs exactly as it does for ⌘Q — idle shells
/// die, running ones stay in the daemon, the launch agent exits when it
/// holds nothing. Reached through the ObjC runtime because a Catalyst
/// target cannot import AppKit.
enum AppTermination {
    @MainActor
    static func terminate() {
        guard let appClass = NSClassFromString("NSApplication") as? NSObject.Type,
              let app = appClass.perform(NSSelectorFromString("sharedApplication"))?.takeUnretainedValue() as? NSObject
        else { exit(0) }
        _ = app.perform(NSSelectorFromString("terminate:"), with: nil)
    }
}
