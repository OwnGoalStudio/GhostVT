//
//  TextSize.swift
//  iGhostVT
//

import Foundation
import SwiftUI

/// The interface's text size, kept as steps around the platform's own
/// size rather than as a size of its own. Zero is the platform default;
/// each step multiplies every `DS.Font` role by ten percent, on top of
/// whatever the system's Dynamic Type setting already did on iOS. A
/// multiplier, not a `dynamicTypeSize` override, because Catalyst never
/// scales a text style with the content size category.
enum InterfaceTextSize {
    static let key = "Interface.textSizeStep"

    /// Roughly two thirds to double the default size.
    static let steps = -4 ... 8

    static func scale(step: Int) -> CGFloat {
        pow(1.1, CGFloat(min(max(step, steps.lowerBound), steps.upperBound)))
    }
}

/// The font size a new terminal opens at. Only *new* surfaces read it: an
/// open tab keeps whatever size the user pinched or ⌘-zoomed it to, and the
/// library seeds that zoom from the surface's own size, so the first pinch
/// continues from here instead of jumping.
enum TerminalFontSize {
    static let key = "Terminal.fontSize"

    /// The Mac gets libghostty's own default; the device keeps the smaller
    /// size the library's default configuration renders there.
    #if targetEnvironment(macCatalyst)
        static let `default` = 14
    #else
        static let `default` = 10
    #endif

    /// The library's own zoom limits, so the stepper and the pinch agree on
    /// where the ends are.
    static let range = 4 ... 64

    /// The stored size, clamped, as the surface configuration wants it.
    static var preferred: Float {
        Float(stored)
    }

    private static var stored: Int {
        let value = UserDefaults.standard.object(forKey: key) as? Int ?? `default`
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// View ▸ Bigger / Smaller: the active surface zooms by one point and
    /// the preference follows it, so the next tab opens at the same size.
    static func stepPreferred(by delta: Int) {
        let value = min(max(stored + delta, range.lowerBound), range.upperBound)
        UserDefaults.standard.set(value, forKey: key)
    }

    /// View ▸ Actual Size: back to the platform default.
    static func resetPreferred() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
