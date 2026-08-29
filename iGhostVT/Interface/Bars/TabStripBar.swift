//
//  TabStripBar.swift
//  iGhostVT
//

import SwiftUI

/// Safari-for-iPad-style top bar for regular width. With the sidebar closed
/// it shows scrollable tab chips; with the sidebar open the tabs live there
/// and this bar shows the active tab's title instead.
struct TabStripBar: View {
    /// The bar's height: its controls plus the padding above and below.
    /// The Mac's traffic lights are centred on it (`CatalystWindowChrome`).
    static let height: CGFloat = DS.Padding.s + controlSize + DS.Padding.s
    static let controlSize: CGFloat = 40

    @ObservedObject var tabManager: TabManager
    @Binding var showsSidebar: Bool
    @State private var window: UIWindow?

    var body: some View {
        GlassBarContainer(spacing: DS.Padding.s) {
            HStack(spacing: DS.Padding.s) {
                Button(action: { showsSidebar.toggle() }) {
                    Image(systemName: "sidebar.leading")
                        .font(DS.Font.control)
                        .frame(width: Self.controlSize, height: Self.controlSize)
                        .contentShape(Circle())
                }
                .barGlass(in: Circle())
                .accessibilityLabel("Toggle Sidebar")

                if tabManager.tabs.isEmpty {
                    // With no tabs there is nothing to title or strip: an
                    // empty capsule collapses to its padding — an 8pt line
                    // squashed across the bar — so the empty state yields the
                    // space instead.
                    Spacer()
                } else {
                    centerCapsule
                }

                // The bar's only trailing control: the sidebar owns settings
                // and doubles as the tab overview at this width, so the strip
                // carries neither entry. New Window rides the long-press,
                // Safari-style.
                Button(action: { tabManager.newTab() }) {
                    Image(systemName: "plus")
                        .font(DS.Font.control)
                        .frame(width: Self.controlSize, height: Self.controlSize)
                        .contentShape(Circle())
                }
                .barGlass(in: Circle())
                .contextMenu { windowMenu }
                .accessibilityLabel("New Tab")
            }
            .padding(.horizontal, DS.Padding.l)
            .padding(.leading, windowControlsInset)
            .padding(.top, DS.Padding.s)
            .padding(.bottom, DS.Padding.s)
            .background(WindowDragRegion())
        }
        .buttonStyle(.plain)
        // For the context menu's share sheet, which presents via UIKit.
        .background(WindowReader(window: $window))
    }

    /// With the sidebar hidden, the Mac's traffic lights float over this
    /// bar's leading end; the sidebar toggle moves out from under them.
    private var windowControlsInset: CGFloat {
        #if targetEnvironment(macCatalyst)
            showsSidebar ? 0 : CatalystWindowChrome.windowControlsWidth - DS.Padding.l
        #else
            0
        #endif
    }

    @ViewBuilder
    private var windowMenu: some View {
        Button(action: { TerminalWindow.requestNewWindow() }) {
            Label("New Window", systemImage: "macwindow.badge.plus")
        }
    }

    /// One capsule for both modes. The bar is a glass-effect container, and
    /// replacing a glass capsule with another one makes Liquid Glass morph
    /// between them — a blob that shrinks to a pill and regrows while the
    /// sidebar slides. The shape stays mounted; only its content crossfades.
    private var centerCapsule: some View {
        // Leading, like the chips: a program that retitles on every prompt
        // (a status line, an agent reporting progress) would otherwise
        // re-centre the text at each change, and the dot with it.
        ZStack(alignment: .leading) {
            if showsSidebar {
                if let tab = tabManager.activeTab {
                    HStack(spacing: DS.Padding.s) {
                        ObservedStatusDot(store: tab.store, font: .labelEmphasis)
                        ObservedTabTitle(tab: tab)
                        ObservedTabSubtitle(tab: tab)
                    }
                    .padding(.horizontal, DS.Padding.l)
                    .contextMenu {
                        TabContextMenu(tab: tab, tabManager: tabManager, window: window)
                    }
                    // Keyed on the tab: switching tabs (a new one included)
                    // crossfades one title for another. Without the key
                    // SwiftUI reads it as the same text changing and morphs
                    // the two — strings overlapping mid-slide, the dot
                    // drifting after them.
                    .id(tab.id)
                    .transition(.opacity)
                }
            } else {
                chipStrip
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Self.controlSize, alignment: .leading)
        .barGlass(in: Capsule(), interactive: false)
    }

    /// Chips share the bar Safari-style: equal widths, the bar divided by
    /// the tab count and clamped to ``TabChip/widthRange``, so a title that
    /// keeps changing never resizes its chip or shoves its neighbours, and
    /// the strip scrolls only once the minimums no longer fit.
    private var chipStrip: some View {
        GeometryReader { proxy in
            let count = CGFloat(max(tabManager.tabs.count, 1))
            let available = proxy.size.width - DS.Padding.xs * 2 - DS.Padding.xs * (count - 1)
            let width = min(TabChip.widthRange.upperBound, max(TabChip.widthRange.lowerBound, available / count))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Padding.xs) {
                    ForEach(tabManager.tabs) { tab in
                        TabChip(
                            tab: tab,
                            isActive: tab.id == tabManager.activeTabID,
                            onSelect: { tabManager.activeTabID = tab.id },
                            onClose: { tabManager.requestClose(tab) }
                        )
                        .frame(width: width)
                        .contextMenu {
                            TabContextMenu(tab: tab, tabManager: tabManager, window: window)
                        }
                    }
                }
                .padding(DS.Padding.xs)
            }
        }
        // A GeometryReader fills whatever it is given, in both axes; the
        // bar's height is the capsule's, not the window's.
        .frame(maxWidth: .infinity, maxHeight: Self.controlSize, alignment: .leading)
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
            .retitleTransition()
            .animation(DS.Motion.smooth, value: tab.displayTitle)
    }
}

/// The dim line beside the title: what the session reports about itself
/// while the title itself stays the stable process name.
struct ObservedTabSubtitle: View {
    @ObservedObject var tab: TerminalTab

    var body: some View {
        Text(tab.secondaryTitle)
            .font(DS.Font.caption)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .retitleTransition()
            .animation(DS.Motion.smooth, value: tab.secondaryTitle)
    }
}

private extension View {
    /// A retitle crossfades the text instead of swapping it. The shell
    /// retitles a fresh tab within a second of its prompt appearing, so
    /// "Terminal" turning into a host name is the first thing a new tab
    /// does — worth more than a hard cut.
    @ViewBuilder
    func retitleTransition() -> some View {
        if #available(iOS 16.0, *) {
            contentTransition(.opacity)
        } else {
            self
        }
    }
}

private struct TabChip: View {
    @ObservedObject var tab: TerminalTab
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    /// The floor keeps the close button clear of the status dot — a tap
    /// near the dot must select, not close; the ceiling keeps one long
    /// title from owning the bar.
    static let widthRange: ClosedRange<CGFloat> = 120 ... 240

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: DS.Padding.xs) {
                ObservedStatusDot(store: tab.store, font: .label)
                Text(tab.displayTitle)
                    .font(DS.Font.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .retitleTransition()
                    .frame(maxWidth: .infinity, alignment: .leading)
                if tab.isLocked {
                    Image(systemName: "lock.fill")
                        .font(DS.Font.captionEmphasis)
                        .foregroundColor(.secondary)
                }
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
            // A retitle changes the chip's width; the chips after it slide
            // over instead of jumping.
            .animation(DS.Motion.smooth, value: tab.displayTitle)
        }
    }
}
