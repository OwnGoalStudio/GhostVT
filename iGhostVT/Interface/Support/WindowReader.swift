//
//  WindowReader.swift
//  iGhostVT
//

import SwiftUI
import UIKit

/// Reports the `UIWindow` the attachment point lands in, for the few places
/// SwiftUI needs a UIKit presentation context (`AlertViewController`).
/// Attach as a `.background`.
struct WindowReader: UIViewRepresentable {
    @Binding var window: UIWindow?

    func makeUIView(context _: Context) -> Probe {
        let probe = Probe()
        probe.isUserInteractionEnabled = false
        probe.onWindow = { window = $0 }
        return probe
    }

    func updateUIView(_ probe: Probe, context _: Context) {
        probe.onWindow = { window = $0 }
    }

    final class Probe: UIView {
        var onWindow: (UIWindow?) -> Void = { _ in }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // Deferred: didMoveToWindow can fire inside a SwiftUI update, and
            // the binding write must not land in the same transaction.
            let window = window
            DispatchQueue.main.async { [self] in
                onWindow(window)
            }
        }
    }
}
