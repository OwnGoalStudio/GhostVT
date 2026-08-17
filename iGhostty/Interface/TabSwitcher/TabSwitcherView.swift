import SwiftUI

/// Safari-style tab overview: a grid of live snapshot cards.
struct TabSwitcherView: View {
    @ObservedObject var tabManager: TabManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var theme = AppTheme.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsSettings = false

    private let columns = [
        GridItem(.adaptive(minimum: 170, maximum: 280), spacing: 14),
    ]

    var body: some View {
        ZStack {
            theme.background(for: colorScheme)
                .ignoresSafeArea()

            ScrollView {
                Text(tabCountLabel)
                    .font(.headline)
                    .padding(.top, 12)

                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(tabManager.tabs) { tab in
                        TabCard(
                            tab: tab,
                            isActive: tab.id == tabManager.activeTabID,
                            onSelect: {
                                tabManager.activeTabID = tab.id
                                dismiss()
                            },
                            onClose: { tabManager.requestClose(tab) }
                        )
                    }
                    newTabCard
                }
                .padding(16)
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
        .closeTabConfirmation(tabManager)
    }

    private var tabCountLabel: String {
        tabManager.tabs.count == 1 ? "1 Tab" : "\(tabManager.tabs.count) Tabs"
    }

    private var newTabCard: some View {
        Button(action: {
            tabManager.newTab()
            dismiss()
        }) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    theme.hairline(for: colorScheme),
                    style: StrokeStyle(lineWidth: 1, dash: [6, 4])
                )
                .frame(height: 190)
                .overlay {
                    Image(systemName: "plus")
                        .font(.title2.weight(.medium))
                        .foregroundColor(.secondary)
                }
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New Tab")
    }

    private var bottomBar: some View {
        GlassBarContainer(spacing: 12) {
            HStack {
                // App-level chrome gets the app-level control: the grid's
                // dashed card is already the one `+`, and settings needs a
                // visible home on iPhone beyond the title's long-press.
                Button(action: { showsSettings = true }) {
                    Image(systemName: "gearshape")
                        .font(.body.weight(.medium))
                        .frame(width: 44, height: 44)
                }
                .barGlass(in: Circle())
                .accessibilityLabel("Settings")

                Spacer()

                Button(action: { dismiss() }) {
                    Text("Done")
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 20)
                        .frame(height: 44)
                }
                .barGlass(in: Capsule())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
}

private struct TabCard: View {
    @ObservedObject var tab: TerminalTab
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @ObservedObject private var theme = AppTheme.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var preview = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            previewBody
        }
        .background(theme.background(for: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isActive ? Color.accentColor : theme.hairline(for: colorScheme),
                    lineWidth: isActive ? 2 : 1
                )
        }
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture(perform: onSelect)
        .onAppear { preview = tab.snapshotPreview() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            ObservedStatusDot(store: tab.store)
            Text(tab.displayTitle)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Tab")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.06))
    }

    private var previewBody: some View {
        Text(preview.isEmpty ? " " : preview)
            .font(.system(size: 7, design: .monospaced))
            .lineSpacing(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(8)
            .clipped()
            .frame(height: 156)
            .accessibilityHidden(true)
    }
}
