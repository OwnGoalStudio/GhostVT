//
//  Spacing.swift
//  iGhostVTWidgets
//

import CoreGraphics

/// The three gaps this widget is allowed to use — a 4pt geometric scale, so
/// spacing reads as deliberate instead of per-view guesswork.
enum Spacing {
    /// Between lines, and between a status dot and its text.
    static let line: CGFloat = 8
    /// Between the icon block and the text block.
    static let block: CGFloat = 12
    /// The lock screen card's outer padding.
    static let card: CGFloat = 16
}
