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
                    HStack(spacing: 10) {
                        Image(systemName: "plus")
                            .font(.subheadline.weight(.medium))
                            .frame(width: 16)
                        Text("New Tab")
                            .font(.subheadline)
                        Spacer()
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New Tab")
            }
            .padding(10)
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .background(
            Color.primary.opacity(0.04)
                .background(theme.background(for: colorScheme))
                .ignoresSafeArea()
        )
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
                .font(.headline)
            Spacer()
            Text(countLabel)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    /// Settings' home at regular width — the top bar carries no gear, so
    /// this corner is the one visible entry (⌘, works regardless).
    private var footer: some View {
        HStack {
            Button(action: onShowSettings) {
                Image(systemName: "gearshape")
                    .font(.body.weight(.medium))
                    .foregroundColor(.secondary)
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
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
            HStack(spacing: 10) {
                ObservedStatusDot(store: tab.store)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tab.displayTitle)
                        .font(.subheadline.weight(isActive ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(tab.store.endpointDescription)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close Tab")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isActive ? Color.accentColor.opacity(0.18) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
