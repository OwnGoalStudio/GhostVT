//
//  DesignSystem.swift
//  iGhostty
//

import SwiftUI

/// The app's design tokens. Interface code speaks these — raw point values,
/// ad-hoc font stacks, and one-off animation curves belong here, not at call
/// sites. Each scale is deliberately small: when a new value seems needed,
/// pick the nearest step instead of adding one.
enum DS {
    /// Spacing scale, for paddings and stack spacing alike.
    enum Padding {
        /// 4 — hairline gaps: badge insets, chip innards.
        static let xs: CGFloat = 4
        /// 8 — tight: icon-to-label, bar interiors.
        static let s: CGFloat = 8
        /// 12 — control padding: row insets, cluster gaps.
        static let m: CGFloat = 12
        /// 16 — container padding: bars, cards, grids.
        static let l: CGFloat = 16
        /// 24 — breathing room: empty states, hero layouts.
        static let xl: CGFloat = 24
    }

    /// Corner radii. Continuous curvature at the call site.
    enum Radius {
        /// 6 — small accents: swatches, thumbnails.
        static let s: CGFloat = 6
        /// 12 — controls: buttons, rows, icon wells.
        static let m: CGFloat = 12
        /// 16 — containers: cards, sheets, panes.
        static let l: CGFloat = 16
    }

    /// Text roles. Sizes ride Dynamic Type through the system styles.
    enum Font {
        /// Section and card titles.
        static let title = SwiftUI.Font.headline
        /// Bar buttons and standalone control glyphs.
        static let control = SwiftUI.Font.body.weight(.medium)
        /// The emphasized control: confirmations, filled buttons.
        static let controlEmphasis = SwiftUI.Font.body.weight(.semibold)
        /// Plain body copy.
        static let body = SwiftUI.Font.body
        /// List rows, chips, and secondary copy.
        static let label = SwiftUI.Font.subheadline
        /// The selected or leading variant of `label`.
        static let labelEmphasis = SwiftUI.Font.subheadline.weight(.semibold)
        /// Footers and explanatory copy.
        static let detail = SwiftUI.Font.footnote
        /// Timestamps, counts, subtitles.
        static let caption = SwiftUI.Font.caption
        /// Tiny controls that must hold their own: badges, close glyphs.
        static let captionEmphasis = SwiftUI.Font.caption.weight(.semibold)
        /// Monospaced body (paths, commands).
        static let mono = SwiftUI.Font.body.monospaced()
        /// Monospaced caption (file paths in footers).
        static let monoCaption = SwiftUI.Font.caption.monospaced()
        /// Large symbol glyphs sitting alone in a row or card.
        static let symbol = SwiftUI.Font.title3
        /// The one oversized symbol of an empty state.
        static let heroSymbol = SwiftUI.Font.system(size: 52, weight: .light)
    }

    /// Motion. One spring family — no linear or eased curves, so every
    /// movement decelerates the same way.
    enum Motion {
        /// The default for state changes the eye should glide through.
        static let smooth = Animation.spring(response: 0.45, dampingFraction: 1.0)
        /// Quick flips: press feedback, drag-state highlights.
        static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.9)
        /// Structural changes: tabs appearing and leaving, panes moving.
        /// A whisper of overshoot keeps insertions lively.
        static let structure = Animation.spring(response: 0.45, dampingFraction: 0.88)
    }
}
