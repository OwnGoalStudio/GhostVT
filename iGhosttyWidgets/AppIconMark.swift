//
//  AppIconMark.swift
//  iGhosttyWidgets
//

import SwiftUI

/// The app's own icon, masked the way the system masks it elsewhere. The
/// asset carries light and dark renditions; the island always resolves the
/// dark one because the system renders it with a dark trait collection.
struct AppIconMark: View {
    var size: CGFloat

    var body: some View {
        Image("WidgetIcon")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }
}
