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
        GlassBarContainer(spacing: DS.Padding.m) {
            HStack(spacing: DS.Padding.m) {
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
                        .font(DS.Font.control)
                        .frame(width: 44, height: 44)
                }
                .barGlass(in: Circle())
                .accessibilityLabel("New Tab")

                Button(action: onShowSwitcher) {
                    Image(systemName: "square.on.square")
                        .font(DS.Font.control)
                        .frame(width: 44, height: 44)
                        .overlay(alignment: .topTrailing) {
                            if tabManager.tabs.count > 1 {
                                Text("\(tabManager.tabs.count)")
                                    .font(DS.Font.captionEmphasis)
                                    .padding(DS.Padding.xs)
                                    .background(Color.accentColor, in: Circle())
                                    .foregroundColor(.white)
                                    .offset(x: 2, y: 2)
                            }
                        }
                }
                .barGlass(in: Circle())
                .accessibilityLabel("Show Tabs")
            }
            .padding(.horizontal, DS.Padding.l)
            .padding(.top, DS.Padding.s)
            .padding(.bottom, DS.Padding.xs)
        }
        .buttonStyle(.plain)
    }

    private var switchTabGesture: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else {
                    return
                }
                withAnimation(DS.Motion.snappy) {
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
        HStack(spacing: DS.Padding.s) {
            ObservedStatusDot(store: tab.store)
            Text(tab.displayTitle)
                .font(DS.Font.labelEmphasis)
                .lineLimit(1)
                .truncationMode(.middle)
            ObservedTabSubtitle(tab: tab)
        }
        .padding(.horizontal, DS.Padding.l)
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
