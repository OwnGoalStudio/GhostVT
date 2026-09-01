import SwiftUI
import UIKit

extension View {
    /// Liquid Glass on iOS 26+, material capsule/shape fallback below.
    ///
    /// `geometryGroup()` where available: the glass/material layer renders
    /// out-of-band from SwiftUI's geometry interpolation, so a layout shift
    /// (the sidebar opening) moves the label first and drags the background
    /// a beat behind it. Grouping resolves the subtree's geometry in one
    /// transaction so both travel together. iOS 15/16 have no equivalent.
    ///
    /// visionOS has no `glassEffect`; its windows are already glass, so the
    /// material fallback is the whole treatment there.
    @ViewBuilder
    func barGlass(in shape: some Shape, interactive: Bool = true) -> some View {
        #if os(visionOS)
            background(.ultraThinMaterial, in: shape)
                .geometryGroup()
        #else
            if #available(iOS 26.0, *) {
                glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
                    .geometryGroup()
            } else if #available(iOS 17.0, *) {
                background(.ultraThinMaterial, in: shape)
                    .geometryGroup()
            } else {
                background(.ultraThinMaterial, in: shape)
            }
        #endif
    }
}

extension View {
    /// The card treatment — the alert, the Mac's settings panel: Liquid
    /// Glass on iOS 26+, the material card it replaces below. The content is
    /// clipped to the shape either way, so a scrolling pane inside stays
    /// within the corners.
    @ViewBuilder
    func cardGlass(in shape: some Shape) -> some View {
        #if os(visionOS)
            clipShape(shape)
                .background(.regularMaterial)
                .background(Color(UIColor.systemBackground).opacity(0.5))
                .clipShape(shape)
        #else
            if #available(iOS 26.0, *) {
                clipShape(shape)
                    .glassEffect(.regular, in: shape)
            } else {
                clipShape(shape)
                    .background(.regularMaterial)
                    .background(Color(UIColor.systemBackground).opacity(0.5))
                    .clipShape(shape)
            }
        #endif
    }
}

/// `GlassEffectContainer` when available so sibling glass elements share one
/// sampling region; transparent grouping otherwise.
struct GlassBarContainer<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if os(visionOS)
            content()
        #else
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: spacing, content: content)
            } else {
                content()
            }
        #endif
    }
}
