import SwiftUI
import UIKit

/// Safari-style tab overview: a grid of live snapshot cards.
struct TabSwitcherView: View {
    @ObservedObject var tabManager: TabManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var theme = AppTheme.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsSettings = false
    @State private var window: UIWindow?

    private let columns = [
        GridItem(.adaptive(minimum: 170, maximum: 280), spacing: 14),
    ]

    var body: some View {
        ZStack {
            theme.background(for: colorScheme)
                .ignoresSafeArea()

            ScrollView {
                Text(tabCountLabel)
                    .font(DS.Font.title)
                    .padding(.top, DS.Padding.m)

                LazyVGrid(columns: columns, spacing: DS.Padding.m) {
                    ForEach(tabManager.tabs) { tab in
                        TabCard(
                            tab: tab,
                            isActive: tab.id == tabManager.activeTabID,
                            onSelect: {
                                tabManager.activeTabID = tab.id
                                dismiss()
                            },
                            onClose: { tabManager.requestClose(tab) },
                            tabManager: tabManager,
                            window: window
                        )
                    }
                    newTabCard
                }
                .padding(DS.Padding.l)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
        }
        // Settings stays a sheet ON the switcher: dismissing the switcher
        // first and then presenting would race the dismissal animation, the
        // same dead-entry bug the title capsule's context menu had.
        .sheet(isPresented: $showsSettings) {
            SettingsSheet()
        }
        // Close-tab confirmations need no copy here: the root's presents on
        // the front-most context, which is this cover while it is up.
        .background(WindowReader(window: $window))
    }

    private var tabCountLabel: String {
        String.localizedStringWithFormat(
            NSLocalizedString("%lld Tabs", comment: "Count of open tabs, as a heading"),
            tabManager.tabs.count
        )
    }

    private var newTabCard: some View {
        Button(action: {
            tabManager.newTab()
            dismiss()
        }) {
            RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                .strokeBorder(
                    theme.hairline(for: colorScheme),
                    style: StrokeStyle(lineWidth: 1, dash: [6, 4])
                )
                .frame(height: 190)
                .overlay {
                    Image(systemName: "plus")
                        .font(DS.Font.symbol)
                        .foregroundColor(.secondary)
                }
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New Tab")
    }

    private var bottomBar: some View {
        GlassBarContainer(spacing: DS.Padding.m) {
            HStack {
                // App-level chrome gets the app-level control: the grid's
                // dashed card is already the one `+`, and settings needs a
                // visible home on iPhone beyond the title's long-press.
                Button(action: { showsSettings = true }) {
                    Image(systemName: "gearshape")
                        .font(DS.Font.control)
                        .frame(width: 44, height: 44)
                }
                .barGlass(in: Circle())
                .accessibilityLabel("Settings")

                Spacer(minLength: 8)

                // Only with tabs to close: an empty window already says so in
                // the grid, and a dead destructive control beside it reads as
                // a bug.
                if !tabManager.tabs.isEmpty {
                    Button(action: { requestCloseAll() }) {
                        Text("Close All")
                            .font(DS.Font.control)
                            .foregroundColor(.red)
                            .padding(.horizontal, DS.Padding.l)
                            .frame(height: 44)
                    }
                    .barGlass(in: Capsule())

                    Spacer(minLength: 8)
                }

                Button(action: { dismiss() }) {
                    Text("Done")
                        .font(DS.Font.controlEmphasis)
                        .padding(.horizontal, DS.Padding.l)
                        .frame(height: 44)
                }
                .barGlass(in: Capsule())
            }
            .padding(.horizontal, DS.Padding.l)
            .padding(.vertical, DS.Padding.s)
        }
        .buttonStyle(.plain)
    }

    /// Same rule as a single tab's ×: ask first when running programs would
    /// die, close straight away when there is nothing to lose.
    private func requestCloseAll() {
        guard tabManager.hasRunningPrograms else {
            tabManager.closeAll()
            return
        }
        AlertViewController(
            title: "Close All Tabs?",
            message: "This closes all tabs and stops everything running in them.",
            actions: [
                AlertAction("Cancel"),
                AlertAction("Close All", kind: .destructive) {
                    tabManager.closeAll()
                },
            ]
        ).present(in: window)
    }
}

private struct TabCard: View {
    @ObservedObject var tab: TerminalTab
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let tabManager: TabManager
    let window: UIWindow?
    @ObservedObject private var theme = AppTheme.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var preview = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            previewBody
        }
        .background(theme.background(for: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                .strokeBorder(
                    isActive ? Color.accentColor : theme.hairline(for: colorScheme),
                    lineWidth: isActive ? 2 : 1
                )
        }
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
        .contextMenu {
            TabContextMenu(tab: tab, tabManager: tabManager, window: window)
        }
        .onTapGesture(perform: onSelect)
        .onAppear { preview = tab.snapshotPreview() }
    }

    private var header: some View {
        HStack(spacing: DS.Padding.xs) {
            ObservedStatusDot(store: tab.store, font: .captionEmphasis)
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.displayTitle)
                    .font(DS.Font.captionEmphasis)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(tab.secondaryTitle)
                    .font(DS.Font.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if tab.isLocked {
                Image(systemName: "lock.fill")
                    .font(DS.Font.captionEmphasis)
                    .foregroundColor(.secondary)
            }
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
        .background(Color.primary.opacity(0.06))
    }

    private var previewBody: some View {
        Text(preview.isEmpty ? " " : preview)
            .font(.system(size: 7, design: .monospaced))
            .lineSpacing(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(DS.Padding.s)
            .clipped()
            .frame(height: 156)
            .accessibilityHidden(true)
    }
}
