//
//  AppDelegate.swift
//  iGhostty
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
        // (`log stream --process iGhostty`), so a surface that never comes up
        // on device says where it stopped. Input/output categories stay off —
        // they would log keystrokes.
        let ghosttyLog = Logger(subsystem: "wiki.qaq.iGhostty", category: "ghostty")
        TerminalDebugLog.sink = { message in
            ghosttyLog.info("\(message, privacy: .public)")
        }
        TerminalDebugLog.enable([.lifecycle, .metrics])
        // Full tracing (input, IME, output) is opt-in because it logs
        // keystrokes. On a jailbroken device:
        //   defaults write wiki.qaq.iGhostty Debug.verboseTerminalLog -bool true
        // then relaunch and watch with `idevicesyslog` / `log stream`.
        if UserDefaults.standard.bool(forKey: "Debug.verboseTerminalLog") {
            TerminalDebugLog.enable(.standard)
        }
        return true
    }
}
