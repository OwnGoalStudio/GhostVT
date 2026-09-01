//
//  OverlayPanelController.swift
//  iGhostVT
//

import SwiftUI
import UIKit

/// A SwiftUI pane presented over the whole window with a cross-dissolve —
/// the presentation `AlertViewController` established, shared with the
/// Mac's settings panel. `.overFullScreen` keeps the presenter's view in
/// place under the dim, so nothing underneath re-lays out or flashes the
/// way a Catalyst sheet does on its way in and out.
///
/// Subclasses call `install(_:)` from `viewDidLoad` with the pane to host;
/// it is pinned edge to edge and given the interface text size, since a
/// hosting controller starts from a fresh environment.
class OverlayPanelController: UIViewController {
    init() {
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    func install(_ pane: some View) {
        let host = UIHostingController(rootView: pane.interfaceTextSize())
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
    }

    /// Presents on the window's front-most presentation context, so a panel
    /// raised while a sheet or full-screen cover is up lands above it instead
    /// of failing on a covered presenter.
    func present(in window: UIWindow?) {
        guard var presenter = window?.rootViewController else { return }
        while let presented = presenter.presentedViewController,
              !presented.isBeingDismissed
        {
            presenter = presented
        }
        presenter.present(self, animated: true)
    }
}
