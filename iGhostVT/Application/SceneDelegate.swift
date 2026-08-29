//
//  SceneDelegate.swift
//  iGhostVT
//

import Combine
import SwiftUI
import UIKit

/// One window, one `TabManager`: every scene owns its tabs and their
/// connections, the way Safari windows own their tabs. When the system
/// discards the scene, the window's sessions are torn down with it.
@objc(SceneDelegate)
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    /// Read by `AppDelegate.applicationWillTerminate`, which walks every
    /// connected scene's tabs to decide what the quit closes.
    let tabManager = TabManager()
    private let interface = WindowInterfaceState()

    /// Watches the Mac's background helper. Nothing on iOS ever publishes.
    private var agentObserver: AnyCancellable?

    func scene(
        _ scene: UIScene,
        willConnectTo _: UISceneSession,
        options _: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        // The window answers the menu bar's commands for these tabs.
        let window = TerminalWindow(
            windowScene: windowScene,
            tabManager: tabManager,
            interface: interface
        )
        window.rootViewController = UIHostingController(
            rootView: RootView(tabManager: tabManager, interface: interface).interfaceTextSize()
        )
        window.makeKeyAndVisible()
        self.window = window
        observeLaunchAgent()
    }

    /// Approval happens in System Settings, outside the app, and there is no
    /// callback for it — the app finds out by looking. Two things look: the
    /// status re-read on every activation below, and this subscription, which
    /// turns "the helper is now running" into the connection attempt the tabs
    /// never got to make at launch.
    private func observeLaunchAgent() {
        agentObserver = MacLaunchAgent.shared.$status
            .removeDuplicates()
            // Only *transitions* to enabled. `@Published` replays its current
            // value on subscribe, and acting on that would start connecting
            // from `willConnectTo` — before the scene is active, which is the
            // one thing the auto-connect ordering exists to avoid.
            .dropFirst()
            .filter { $0 == .enabled }
            .sink { [weak self] _ in
                guard let self else { return }
                tabManager.noteSceneActive()
                tabManager.retryFailedTabs()
            }
    }

    func sceneDidDisconnect(_: UIScene) {
        tabManager.detachAllTabs()
    }

    /// Sessions auto-connect only from here on: the launch transition is
    /// over, layout has settled, and surfaces render unoccluded — the
    /// viewport a shell spawns with is the one the user actually sees.
    ///
    /// On the Mac there is one more precondition. The daemon is a bundled
    /// LaunchAgent a person has to allow once, and connecting before that is
    /// approved buys a guaranteed failure and a "Terminal Unavailable" card
    /// that names the wrong problem. So the first attempt waits for the
    /// helper, and `observeLaunchAgent()` makes it when the helper arrives.
    func sceneDidBecomeActive(_: UIScene) {
        MacLaunchAgent.shared.refresh()
        guard MacLaunchAgent.shared.isReady else { return }
        tabManager.noteSceneActive()
    }

    /// Nothing ends the Live Activity while the app isn't running, so a
    /// return to the foreground re-reads the daemon's registry — if the
    /// detached shells it was advertising died in the meantime, this is the
    /// moment the activity finds out and folds.
    func sceneWillEnterForeground(_: UIScene) {
        DaemonSessionDirectory.shared.refresh()
    }
}
