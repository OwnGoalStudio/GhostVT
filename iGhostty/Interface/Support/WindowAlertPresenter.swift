//
//  WindowAlertPresenter.swift
//  iGhostty
//

import Combine
import SwiftUI
import UIKit

/// Presents a request the model raises as one `AlertViewController`.
///
/// Attached once, at the window root: the alert lands on the window's
/// front-most presentation context, so a request raised under the tab
/// switcher's full-screen cover presents above the switcher, and no second
/// copy is needed the way a covered `.alert` used to demand.
///
/// `requests` publishes the model's pending request, `nil` once answered.
/// Every action of the alert `makeAlert` builds must call `finish`, which
/// clears the presentation and then `onFinish`, where the model clears (or
/// advances) its request.
@MainActor
struct WindowAlertPresenter<Request, Requests: Publisher>: ViewModifier
    where Requests.Output == Request?, Requests.Failure == Never
{
    let requests: Requests
    let onFinish: @MainActor () -> Void
    let makeAlert: @MainActor (Request, _ finish: @escaping () -> Void) -> AlertViewController

    @State private var window: UIWindow?
    @State private var pending: Request?
    @State private var presented: AlertViewController?

    func body(content: Content) -> some View {
        content
            .background(WindowReader(window: $window))
            .onReceive(requests) { request in
                pending = request
                present()
            }
            // A request raised before the window was read waits for it.
            .onChange(of: window == nil) { _ in present() }
    }

    private func present() {
        guard let request = pending, let window, presented == nil else { return }
        let alert = makeAlert(request) {
            presented = nil
            pending = nil
            onFinish()
        }
        presented = alert
        alert.present(in: window)
    }
}
