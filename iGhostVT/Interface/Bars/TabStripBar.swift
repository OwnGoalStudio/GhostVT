//
//  TabStripBar.swift
//  iGhostVT
//

import SwiftUI

/// Safari-for-iPad-style top bar for regular width. With the sidebar closed
/// it shows scrollable tab chips; with the sidebar open the tabs live there
/// and this bar shows the active tab's title instead.
struct TabStripBar: View {
    @ObservedObject var tabManager: TabManager
    @Binding var showsSidebar: Bool

    var body: some View {
        GlassBarContainer(spacing: DS.Padding.s) {
            HStack(spacing: DS.Padding.s) {
                Button(action: { showsSidebar.toggle() }) {
                    Image(systemName: "sidebar.leading")
                        .font(DS.Font.control)
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
                        .font(DS.Font.control)
                        .frame(width: 40, height: 40)
                }
                .barGlass(in: Circle())
                .contextMenu { windowMenu }
                .accessibilityLabel("New Tab")
            }
            .padding(.horizontal, DS.Padding.l)
            .padding(.top, DS.Padding.s)
            .padding(.bottom, DS.Padding.s)
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
                HStack(spacing: DS.Padding.s) {
                    ObservedStatusDot(store: tab.store)
                    ObservedTabTitle(tab: tab)
                }
                .padding(.horizontal, DS.Padding.l)
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
                    HStack(spacing: DS.Padding.xs) {
                        ForEach(tabManager.tabs) { tab in
                            TabChip(
                                tab: tab,
                                isActive: tab.id == tabManager.activeTabID,
                                onSelect: { tabManager.activeTabID = tab.id },
                                onClose: { tabManager.requestClose(tab) }
                            )
                        }
                    }
                    .padding(DS.Padding.xs)
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
            .font(DS.Font.labelEmphasis)
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
            HStack(spacing: DS.Padding.xs) {
                ObservedStatusDot(store: tab.store)
                Text(tab.displayTitle)
                    .font(DS.Font.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // The floor keeps a short-titled chip around 100pt, so
                    // the close button never crowds the status dot — a tap
                    // near the dot must select, not close.
                    .frame(minWidth: 44, maxWidth: 180, alignment: .leading)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(DS.Font.captionEmphasis)
                        .foregroundColor(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Circle())
                }
                .accessibilityLabel("Close Tab")
            }
            .padding(.horizontal, DS.Padding.m)
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
