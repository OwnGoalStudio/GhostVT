//
//  SceneDelegate.swift
//  iGhostty
//

import SwiftUI
import UIKit

/// One window, one `TabManager`: every scene owns its tabs and their
/// connections, the way Safari windows own their tabs. When the system
/// discards the scene, the window's sessions are torn down with it.
@objc(SceneDelegate)
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private let tabManager = TabManager()

    func scene(
        _ scene: UIScene,
        willConnectTo _: UISceneSession,
        options _: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(
            rootView: RootView(tabManager: tabManager)
        )
        window.makeKeyAndVisible()
        self.window = window
    }

    func sceneDidDisconnect(_: UIScene) {
        tabManager.detachAllTabs()
    }

    /// Sessions auto-connect only from here on: the launch transition is
    /// over, layout has settled, and surfaces render unoccluded — the
    /// viewport a shell spawns with is the one the user actually sees.
    func sceneDidBecomeActive(_: UIScene) {
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
