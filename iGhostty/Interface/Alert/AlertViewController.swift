//
//  AlertViewController.swift
//  iGhostty
//

import SwiftUI
import UIKit

/// The app's replacement for `UIAlertController` (and the SwiftUI `.alert`
/// that wraps it): the same `AlertCardView` that `SessionStatusOverlay` draws
/// inline, presented over a dimmed pane with a cross-dissolve. Every action
/// dismisses the alert before its handler runs.
///
/// Title and message are `String.LocalizationValue`, so call sites keep
/// passing literals — including interpolated ones like `"Close “\(name)”?"`,
/// whose key stays `Close “%@”?` — and localization keeps working implicitly,
/// exactly as it did in `.alert`'s `LocalizedStringKey` positions.
final class AlertViewController: UIViewController {
    private let alertTitle: String
    private let alertMessage: String
    private let actions: [AlertAction]

    init(
        title: String.LocalizationValue,
        message: String.LocalizationValue,
        actions: [AlertAction]
    ) {
        alertTitle = String(localized: title)
        alertMessage = String(localized: message)
        self.actions = actions
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

        let dismissing = actions.map { action in
            AlertAction(verbatim: action.title, kind: action.kind) { [weak self] in
                self?.dismiss(animated: true, completion: action.handler)
            }
        }
        let host = UIHostingController(
            rootView: AlertPane(
                title: alertTitle,
                message: alertMessage,
                actions: dismissing
            )
        )
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

    /// Presents on the window's front-most presentation context, so an alert
    /// raised while a sheet or full-screen cover is up lands above it instead
    /// of failing on a covered presenter.
    func present(in window: UIWindow?) {
        guard var presenter = window?.rootViewController else { return }
        while let presented = presenter.presentedViewController,
              !presented.isBeingDismissed {
            presenter = presented
        }
        presenter.present(self, animated: true)
    }
}

private struct AlertPane: View {
    let title: String
    let message: String
    let actions: [AlertAction]

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
            AlertCardView(title: title, message: message, actions: actions)
                .padding(16)
        }
    }
}
