import SwiftUI
import UIKit

/// Safari-style floating bottom cluster for compact width: the title capsule
/// (swipe horizontally to switch tabs, long-press for settings), a new-tab
/// button, and the tab switcher.
struct BottomBar: View {
    @ObservedObject var tabManager: TabManager
    let onShowSettings: () -> Void
    let onShowSwitcher: () -> Void

    var body: some View {
        GlassBarContainer(spacing: 12) {
            HStack(spacing: 12) {
                if let tab = tabManager.activeTab {
                    // A long press opens settings directly: a context menu
                    // here loses the long press to the high-priority drag,
                    // and presenting a sheet from a menu action races the
                    // menu's dismissal animation — both read as a dead
                    // settings entry on device.
                    TitleCapsule(tab: tab)
                        .highPriorityGesture(switchTabGesture)
                        .onLongPressGesture {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            onShowSettings()
                        }
                }

                Button(action: { tabManager.newTab() }) {
                    Image(systemName: "plus")
                        .font(.body.weight(.medium))
                        .frame(width: 44, height: 44)
                }
                .barGlass(in: Circle())
                .accessibilityLabel("New Tab")

                Button(action: onShowSwitcher) {
                    Image(systemName: "square.on.square")
                        .font(.body.weight(.medium))
                        .frame(width: 44, height: 44)
                        .overlay(alignment: .topTrailing) {
                            if tabManager.tabs.count > 1 {
                                Text("\(tabManager.tabs.count)")
                                    .font(.caption2.weight(.bold))
                                    .padding(4)
                                    .background(Color.accentColor, in: Circle())
                                    .foregroundColor(.white)
                                    .offset(x: 2, y: 2)
                            }
                        }
                }
                .barGlass(in: Circle())
                .accessibilityLabel("Show Tabs")
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 4)
        }
        .buttonStyle(.plain)
    }

    private var switchTabGesture: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else {
                    return
                }
                withAnimation(.easeInOut(duration: 0.15)) {
                    tabManager.activateAdjacentTab(
                        offset: value.translation.width < 0 ? 1 : -1
                    )
                }
            }
    }
}

private struct TitleCapsule: View {
    @ObservedObject var tab: TerminalTab

    var body: some View {
        HStack(spacing: 8) {
            ObservedStatusDot(store: tab.store)
            Text(tab.displayTitle)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Capsule())
        .barGlass(in: Capsule())
    }
}

/// Status dot that re-renders when the store's status changes.
struct ObservedStatusDot: View {
    @ObservedObject var store: TerminalSessionStore

    var body: some View {
        StatusDot(status: store.status)
    }
}
