//
//  InterfaceTextSizeModifier.swift
//  iGhostVT
//

import SwiftUI

/// Puts the `InterfaceTextSize` preference into the environment, where
/// every `.font(DS.Font.…)` reads it. Goes at the root of every hosting
/// controller — the window's `RootView` and the alert host — since a
/// `UIHostingController` starts from a fresh environment. Sheets and covers
/// presented from inside the tree inherit it on their own.
private struct InterfaceTextSizeModifier: ViewModifier {
    @AppStorage(InterfaceTextSize.key) private var step = 0

    func body(content: Content) -> some View {
        content
            // The default for text with no role of its own (form rows,
            // toggles), so it scales with the rest.
            .font(DS.Font.body)
            .environment(\.interfaceTextScale, InterfaceTextSize.scale(step: step))
    }
}

private struct InterfaceTextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// The multiplier `DS.Font` roles apply; 1 is the platform's own size.
    var interfaceTextScale: CGFloat {
        get { self[InterfaceTextScaleKey.self] }
        set { self[InterfaceTextScaleKey.self] = newValue }
    }
}

extension View {
    /// Sizes every `DS.Font` role under this view by the interface text
    /// size preference; see `InterfaceTextSize`.
    func interfaceTextSize() -> some View {
        modifier(InterfaceTextSizeModifier())
    }
}
