//
//  InterfaceTextSizeModifier.swift
//  iGhostVT
//

import SwiftUI

/// Applies the `InterfaceTextSize` preference to a view tree. Goes at the
/// root of every hosting controller — the window's `RootView` and the alert
/// host — since a `UIHostingController` starts from the system's size, not
/// from whatever its presenter resolved. Sheets and covers presented from
/// inside the tree inherit it on their own.
private struct InterfaceTextSizeModifier: ViewModifier {
    @AppStorage(InterfaceTextSize.key) private var step = 0

    /// Read above the override, so this is the system's own setting.
    @Environment(\.dynamicTypeSize) private var systemSize

    func body(content: Content) -> some View {
        content
            .dynamicTypeSize(InterfaceTextSize.resolve(step: step, system: systemSize))
            .environment(\.systemDynamicTypeSize, systemSize)
    }
}

/// The system's Dynamic Type size, as it was before the app's override —
/// what the Settings stepper measures its bounds from, since by then the
/// environment's `dynamicTypeSize` is the resolved one.
private struct SystemDynamicTypeSizeKey: EnvironmentKey {
    static let defaultValue = DynamicTypeSize.large
}

extension EnvironmentValues {
    var systemDynamicTypeSize: DynamicTypeSize {
        get { self[SystemDynamicTypeSizeKey.self] }
        set { self[SystemDynamicTypeSizeKey.self] = newValue }
    }
}

extension View {
    /// Sizes every text style under this view by the interface text size
    /// preference; see `InterfaceTextSize`.
    func interfaceTextSize() -> some View {
        modifier(InterfaceTextSizeModifier())
    }
}
