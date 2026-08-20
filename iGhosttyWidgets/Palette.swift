//
//  Palette.swift
//  iGhosttyWidgets
//

import SwiftUI

/// Close to the prompt green the terminal itself renders, rather than the
/// system green, so the widget reads as part of the app. The colorsets hold
/// a darkened variant for light backdrops.
enum Palette {
    static let accent = Color("WidgetAccent")
    static let starting = Color("WidgetStarting")
    static let failed = Color("WidgetFailed")
}
