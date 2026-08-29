//
//  TextSize.swift
//  iGhostVT
//

import Foundation
import SwiftUI

/// The interface's text size, kept as steps away from the system's Dynamic
/// Type setting rather than as a size of its own. Zero follows the system;
/// each step is one Dynamic Type size, so the chrome keeps riding the text
/// styles in `DS.Font` and a person who bumps their phone's text size later
/// still gets the bump.
enum InterfaceTextSize {
    static let key = "Interface.textSizeStep"

    /// Every size Dynamic Type has, smallest first.
    static let sizes = DynamicTypeSize.allCases

    /// The size `step` lands on from `system`, held inside the scale.
    static func resolve(step: Int, system: DynamicTypeSize) -> DynamicTypeSize {
        let index = (sizes.firstIndex(of: system) ?? 0) + step
        return sizes[min(max(index, 0), sizes.count - 1)]
    }

    /// The steps that stay on the scale from `system` — the stepper's
    /// bounds, so it stops where the sizes do instead of counting on.
    static func stepRange(from system: DynamicTypeSize) -> ClosedRange<Int> {
        let index = sizes.firstIndex(of: system) ?? 0
        return -index ... sizes.count - 1 - index
    }
}

/// The font size a new terminal opens at. Only *new* surfaces read it: an
/// open tab keeps whatever size the user pinched or ⌘-zoomed it to, and the
/// library seeds that zoom from the surface's own size, so the first pinch
/// continues from here instead of jumping.
enum TerminalFontSize {
    static let key = "Terminal.fontSize"

    /// What the library's default configuration renders on this platform
    /// today, so an untouched install looks the way it did.
    static let `default` = 10

    /// The library's own zoom limits, so the stepper and the pinch agree on
    /// where the ends are.
    static let range = 4 ... 64

    /// The stored size, clamped, as the surface configuration wants it.
    static var preferred: Float {
        let stored = UserDefaults.standard.object(forKey: key) as? Int ?? `default`
        return Float(min(max(stored, range.lowerBound), range.upperBound))
    }
}
