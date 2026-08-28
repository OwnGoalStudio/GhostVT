import SwiftUI

/// Safari-iPad-style sidebar listing tabs for regular width. Selection,
/// close, and new-tab all route through the same `TabManager` the tab strip
/// and switcher use.
struct SidebarView: View {
    @ObservedObject var tabManager: TabManager
    let onShowSettings: () -> Void
    @ObservedObject private var theme = AppTheme.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(tabManager.tabs) { tab in
                        SidebarRow(
                            tab: tab,
                            isActive: tab.id == tabManager.activeTabID,
                            onSelect: { tabManager.activeTabID = tab.id },
                            onClose: { tabManager.requestClose(tab) }
                        )
                    }

                    Button(action: { tabManager.newTab() }) {
                        HStack(spacing: DS.Padding.s) {
                            Image(systemName: "plus")
                                .font(DS.Font.labelEmphasis)
                                .frame(width: 16)
                            Text("New Tab")
                                .font(DS.Font.label)
                            Spacer()
                        }
                        .foregroundColor(.secondary)
                        .padding(.horizontal, DS.Padding.m)
                        .padding(.vertical, DS.Padding.m)
                        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("New Tab")
                }
                .padding(DS.Padding.m)
            }

            footer
        }
        // One standard blur spans the complete sidebar. Keeping it in a
        // single layer avoids the different tints produced when separate
        // materials sample the header, list, and footer independently.
        .background {
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(theme.hairline(for: colorScheme))
                .frame(width: 1)
                .ignoresSafeArea()
        }
    }

    private var header: some View {
        HStack {
            Text("Tabs")
                .font(DS.Font.title)
            Spacer()
            Text(countLabel)
                .font(DS.Font.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, DS.Padding.l)
        .padding(.top, DS.Padding.m)
        .padding(.bottom, DS.Padding.s)
        .frame(maxWidth: .infinity)
    }

    /// Settings' home at regular width — the top bar carries no gear, so
    /// this corner is the one visible entry (⌘, works regardless).
    private var footer: some View {
        HStack {
            Button(action: onShowSettings) {
                Image(systemName: "gearshape")
                    .font(DS.Font.control)
                    .foregroundColor(.secondary)
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
            Spacer()
        }
        .padding(.horizontal, DS.Padding.m)
        .padding(.vertical, DS.Padding.s)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.hairline(for: colorScheme))
                .frame(height: 1)
        }
    }

    private var countLabel: String {
        String.localizedStringWithFormat(
            NSLocalizedString("%lld Tabs", comment: "Count of open tabs, as a heading"),
            tabManager.tabs.count
        )
    }
}

private struct SidebarRow: View {
    @ObservedObject var tab: TerminalTab
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: DS.Padding.s) {
                ObservedStatusDot(store: tab.store)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tab.displayTitle)
                        .font(isActive ? DS.Font.labelEmphasis : DS.Font.label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(tab.store.endpointDescription)
                        .font(DS.Font.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(DS.Font.captionEmphasis)
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close Tab")
            }
            .padding(.horizontal, DS.Padding.m)
            .padding(.vertical, DS.Padding.s)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                    .fill(isActive ? Color.accentColor.opacity(0.18) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
