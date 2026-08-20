//
//  AppIconMark.swift
//  iGhosttyWidgets
//

import SwiftUI

/// A Big Sur-style app icon tile: the ghost glyph on an accent-green
/// gradient squircle. The greens are fixed rather than Palette's adaptive
/// ones — an icon keeps its identity across light and dark.
struct AppIconMark: View {
    var size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(LinearGradient(
                    colors: [
                        Color(red: 0.36, green: 0.89, blue: 0.50),
                        Color(red: 0.16, green: 0.68, blue: 0.33),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ))
            Image("GhostGlyph")
                .resizable()
                .scaledToFit()
                .frame(width: size * 0.72, height: size * 0.72)
        }
        .frame(width: size, height: size)
    }
}
