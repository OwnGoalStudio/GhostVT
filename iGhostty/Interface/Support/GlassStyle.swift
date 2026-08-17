import SwiftUI

extension View {
    /// Liquid Glass on iOS 26+, material capsule/shape fallback below.
    @ViewBuilder
    func barGlass(in shape: some Shape, interactive: Bool = true) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }
}

/// `GlassEffectContainer` when available so sibling glass elements share one
/// sampling region; transparent grouping otherwise.
struct GlassBarContainer<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing, content: content)
        } else {
            content()
        }
    }
}
