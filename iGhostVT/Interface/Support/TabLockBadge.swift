import SwiftUI

/// The glyph a locked tab wears — the strip chip, the switcher card, the
/// active surface's overlay, and the sidebar row's close slot.
///
/// Both lock kinds use the filled padlock. The overlay caption still names
/// which freeze is on (`TabLock.badgeTitle`); the glyph does not.
struct TabLockBadge: View {
    let lock: TabLock
    var font: DS.Font = .captionEmphasis

    var body: some View {
        Image(systemName: "lock.fill")
            .font(font)
            .foregroundColor(.secondary)
            .accessibilityLabel(lock.badgeTitle)
    }
}
