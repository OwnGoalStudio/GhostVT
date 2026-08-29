//
//  WindowDragRegion.swift
//  iGhostVT
//

import SwiftUI
import UIKit

/// A surface that moves the Mac window when dragged — the title bar's job,
/// done by the chrome that replaced it (the sidebar's top strip and footer,
/// the top bar's background). Sits *behind* the real controls as a
/// `background`, so a button above it still wins the press; only a drag that
/// starts on bare chrome reaches it. Inert everywhere but Catalyst.
struct WindowDragRegion: UIViewRepresentable {
    func makeUIView(context _: Context) -> UIView {
        #if targetEnvironment(macCatalyst)
            return DragView()
        #else
            let view = UIView()
            view.isUserInteractionEnabled = false
            return view
        #endif
    }

    func updateUIView(_: UIView, context _: Context) {}

    #if targetEnvironment(macCatalyst)
        private final class DragView: UIView {
            override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
                super.touchesMoved(touches, with: event)
                dispatchTouchAsWindowMovement()
            }
        }
    #endif
}
