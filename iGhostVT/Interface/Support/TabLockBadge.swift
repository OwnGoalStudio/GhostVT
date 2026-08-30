import SwiftUI

/// The glyph a locked tab wears in every presentation — the strip chip, the
/// sidebar row, the switcher card, and the active surface's overlay.
///
/// The two locks each get their own mark, so which freeze is on reads at a
/// glance: `interaction` is the filled padlock; `keyboard` is a keyboard with
/// a slash struck through it. There is no `keyboard.slash` in SF Symbols on
/// this app's iOS 15 floor, so the slash is composed — a diagonal knocked
/// *through* the keyboard (`.destinationOut`) so a real gap shows whatever
/// the badge sits on, then the stroke itself drawn over it. The line widths
/// are fixed points, sized for the caption-scale glyph the badge renders at.
struct TabLockBadge: View {
    let lock: TabLock
    var font: DS.Font = .captionEmphasis

    var body: some View {
        icon
            .font(font)
            .foregroundColor(.secondary)
            .accessibilityLabel(lock.badgeTitle)
    }

    @ViewBuilder
    private var icon: some View {
        switch lock {
        case .interaction:
            Image(systemName: "lock.fill")
        case .keyboard:
            // The slash is confined to the keyboard's own bounds by riding
            // as an overlay: a `Shape` on its own expands to fill whatever it
            // is offered, which would draw a line clear across the row.
            Image(systemName: "keyboard")
                .overlay {
                    Slash()
                        .stroke(style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
                .overlay {
                    Slash().stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                }
        }
    }

    /// Corner to corner, bottom-left to top-right — the angle SF Symbols
    /// draws its own `.slash` variants at.
    private struct Slash: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            return path
        }
    }
}
