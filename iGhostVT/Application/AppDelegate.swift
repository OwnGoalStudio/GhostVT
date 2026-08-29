//
//  AppDelegate.swift
//  iGhostVT
//

import GhosttyTerminal
import os
import UIKit

@objc(AppDelegate)
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Surface lifecycle and sizing into the unified log
        // (`log stream --process iGhostVT`), so a surface that never comes up
        // on device says where it stopped. Input/output categories stay off —
        // they would log keystrokes.
        let ghosttyLog = Logger(subsystem: "wiki.qaq.iGhostVT", category: "ghostty")
        TerminalDebugLog.sink = { message in
            ghosttyLog.info("\(message, privacy: .public)")
        }
        TerminalDebugLog.enable([.lifecycle, .metrics])
        // Full tracing (input, IME, output) is opt-in because it logs
        // keystrokes. On a jailbroken device:
        //   defaults write wiki.qaq.iGhostVT Debug.verboseTerminalLog -bool true
        // then relaunch and watch with `idevicesyslog` / `log stream`.
        if UserDefaults.standard.bool(forKey: "Debug.verboseTerminalLog") {
            TerminalDebugLog.enable(.standard)
        }
        return true
    }

    /// The system menu bar (the Mac, an iPad with a keyboard — where it is
    /// also the hold-⌘ shortcut overlay). The Format menu goes: its ⌘T is
    /// Show Fonts, which shadows New Tab, and a terminal has no rich text
    /// for it to format anyway. `AppMenus` adds the app's own commands;
    /// `TerminalWindow` answers them.
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .main else { return }
        builder.remove(menu: .format)
        AppMenus.install(into: builder)
    }

    /// An explicit quit: ⌘Q on the Mac, or a force-quit on iOS while the app
    /// is still running (a suspended app gets no notice, and its shells stay
    /// in the daemon either way). With Keep Alive off, every shell the daemon
    /// holds — attached to a window or not — dies here, and the connection
    /// goes with it. Files the terminal staged for pastes and drops belong
    /// to those shells; with none left to refer to them, they go too.
    func applicationWillTerminate(_: UIApplication) {
        guard !SessionKeepAlive.isEnabled else { return }
        XPCDaemonTransport.closeAllSessions()
        TerminalFileStaging.removeAllFiles()
    }
}

/// Whether daemon sessions outlive the app. On by default: a shell surviving
/// the app is the point of the daemon. Off is for a Mac (or a user) that
/// wants ⌘Q to mean what it means in Terminal.
enum SessionKeepAlive {
    static let key = "Session.keepAlive"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}
