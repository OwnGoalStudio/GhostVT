//
//  SidebarResizeHandle.swift
//  iGhostVT
//

import SwiftUI

/// The grabber on the sidebar's trailing edge: a rounded-rectangle pill that
/// advertises the width is adjustable, riding a hit area wide enough to
/// actually catch a finger. Dragging resizes the sidebar live — the terminal
/// pane's own resize throttle absorbs the storm of grid changes.
struct SidebarResizeHandle: View {
    @Binding var width: Double

    /// Wide enough for tab titles, narrow enough to leave the terminal a
    /// usable grid in a half-width Split View window.
    static let widthRange: ClosedRange<Double> = 240 ... 420

    /// Width at the drag's start; translations apply against this so a drag
    /// that wanders past a clamp edge and back stays anchored to the finger.
    @State private var dragBaseWidth: Double?
    @State private var isDragging = false

    var body: some View {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(Color.secondary.opacity(isDragging ? 0.8 : 0.4))
            .frame(width: 5, height: 44)
            .frame(width: 20)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                // Global coordinate space: the handle rides the sidebar's
                // trailing edge, so its local space moves with every width
                // change — translations measured there oscillate against the
                // finger and the drag jitters.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let base = dragBaseWidth ?? width
                        dragBaseWidth = base
                        isDragging = true
                        width = (base + value.translation.width)
                            .clamped(to: Self.widthRange)
                    }
                    .onEnded { _ in
                        dragBaseWidth = nil
                        isDragging = false
                    }
            )
            .animation(DS.Motion.snappy, value: isDragging)
            .accessibilityLabel("Resize Sidebar")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: width = (width + 20).clamped(to: Self.widthRange)
                case .decrement: width = (width - 20).clamped(to: Self.widthRange)
                @unknown default: break
                }
            }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
