//
//  TabStripBar.swift
//  iGhostty
//

import SwiftUI

/// Safari-for-iPad-style top bar for regular width. With the sidebar closed
/// it shows scrollable tab chips; with the sidebar open the tabs live there
/// and this bar shows the active tab's title instead.
struct TabStripBar: View {
    @ObservedObject var tabManager: TabManager
    @Binding var showsSidebar: Bool

    var body: some View {
        GlassBarContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button(action: { showsSidebar.toggle() }) {
                    Image(systemName: "sidebar.leading")
                        .font(.body.weight(.medium))
                        .frame(width: 40, height: 40)
                }
                .barGlass(in: Circle())
                .accessibilityLabel("Toggle Sidebar")

                if showsSidebar {
                    activeTitleCapsule
                } else {
                    chipStrip
                }

                // The bar's only trailing control: the sidebar owns settings
                // and doubles as the tab overview at this width, so the strip
                // carries neither entry. New Window rides the long-press,
                // Safari-style.
                Button(action: { tabManager.newTab() }) {
                    Image(systemName: "plus")
                        .font(.body.weight(.medium))
                        .frame(width: 40, height: 40)
                }
                .barGlass(in: Circle())
                .contextMenu { windowMenu }
                .accessibilityLabel("New Tab")
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 8)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var windowMenu: some View {
        Button(action: { RootView.requestNewWindow() }) {
            Label("New Window", systemImage: "macwindow.badge.plus")
        }
    }

    private var activeTitleCapsule: some View {
        Group {
            if let tab = tabManager.activeTab {
                HStack(spacing: 8) {
                    ObservedStatusDot(store: tab.store)
                    ObservedTabTitle(tab: tab)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 40)
                .barGlass(in: Capsule(), interactive: false)
            } else {
                Spacer()
            }
        }
    }

    /// With no tabs there is nothing to strip: an empty capsule collapses to
    /// its padding — an 8pt line squashed across the bar — so the empty
    /// state yields the space instead, mirroring `activeTitleCapsule`.
    private var chipStrip: some View {
        Group {
            if tabManager.tabs.isEmpty {
                Spacer()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(tabManager.tabs) { tab in
                            TabChip(
                                tab: tab,
                                isActive: tab.id == tabManager.activeTabID,
                                onSelect: { tabManager.activeTabID = tab.id },
                                onClose: { tabManager.requestClose(tab) }
                            )
                        }
                    }
                    .padding(4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .barGlass(in: Capsule(), interactive: false)
            }
        }
    }
}

/// Title text that re-renders when the surface retitles (OSC updates).
struct ObservedTabTitle: View {
    @ObservedObject var tab: TerminalTab

    var body: some View {
        Text(tab.displayTitle)
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

private struct TabChip: View {
    @ObservedObject var tab: TerminalTab
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                ObservedStatusDot(store: tab.store)
                Text(tab.displayTitle)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 180)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Circle())
                }
                .accessibilityLabel("Close Tab")
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(
                Capsule().fill(
                    isActive ? Color.primary.opacity(0.12) : Color.clear
                )
            )
            .contentShape(Capsule())
        }
    }
}
