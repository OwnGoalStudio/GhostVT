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
        tabManager.closeAllTabs()
    }
}
