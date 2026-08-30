//
//  AlertViewController.swift
//  iGhostVT
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
    private var hasAnswered = false

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

    /// The terminal under an over-fullscreen presentation keeps first
    /// responder otherwise, so Return would go to the shell instead of the
    /// card.
    override var canBecomeFirstResponder: Bool { true }

    /// Return fires the only action, or the filled one when there are several
    /// (destructive, else accent) — the button the card already emphasizes.
    override var keyCommands: [UIKeyCommand]? {
        guard defaultAction != nil else { return super.keyCommands }
        let command = UIKeyCommand(
            input: "\r",
            modifierFlags: [],
            action: #selector(performDefaultAction)
        )
        command.wantsPriorityOverSystemBehavior = true
        return (super.keyCommands ?? []) + [command]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        let dismissing = actions.map { action in
            AlertAction(verbatim: action.title, kind: action.kind) { [weak self] in
                self?.answer(action)
            }
        }
        let host = Host(
            rootView: AlertPane(
                title: alertTitle,
                message: alertMessage,
                actions: dismissing
            )
            .interfaceTextSize()
        )
        host.owner = self
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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if consumeReturn(presses) { return }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if isUnmodifiedReturn(presses) { return }
        super.pressesEnded(presses, with: event)
    }

    /// Presents on the window's front-most presentation context, so an alert
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

    private var defaultAction: AlertAction? { actions.defaultAction }

    @objc private func performDefaultAction() {
        _ = performDefaultActionIfNeeded()
    }

    fileprivate func consumeReturn(_ presses: Set<UIPress>) -> Bool {
        guard isUnmodifiedReturn(presses) else { return false }
        return performDefaultActionIfNeeded()
    }

    fileprivate func isUnmodifiedReturn(_ presses: Set<UIPress>) -> Bool {
        presses.contains { press in
            guard let key = press.key else { return false }
            let extras = key.modifierFlags.subtracting([.numericPad, .alphaShift])
            guard extras.isEmpty else { return false }
            return key.keyCode == .keyboardReturnOrEnter || key.keyCode == .keypadEnter
        }
    }

    private func performDefaultActionIfNeeded() -> Bool {
        guard let action = defaultAction else { return false }
        answer(action)
        return hasAnswered
    }

    private func answer(_ action: AlertAction) {
        guard !hasAnswered else { return }
        hasAnswered = true
        dismiss(animated: true, completion: action.handler)
    }

    /// Forwards Return before SwiftUI can give it to a focused (often Cancel)
    /// button. The host is typically first responder, not the alert itself.
    private final class Host<Content: View>: UIHostingController<Content> {
        weak var owner: AlertViewController?

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if owner?.consumeReturn(presses) == true { return }
            super.pressesBegan(presses, with: event)
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if owner?.isUnmodifiedReturn(presses) == true { return }
            super.pressesEnded(presses, with: event)
        }
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
                .padding(DS.Padding.l)
        }
    }
}
