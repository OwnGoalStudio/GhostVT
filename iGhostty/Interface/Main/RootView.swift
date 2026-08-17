//
//  RootView.swift
//  iGhostty
//

import GhosttyTerminal
import SwiftUI

/// The window's whole interface. The `TabManager` is owned by the scene
/// delegate; this view (and everything under it) only borrows it, so each
/// window carries independent tabs.
struct RootView: View {
    @ObservedObject var tabManager: TabManager
    @ObservedObject private var theme = AppTheme.shared
    @StateObject private var keyboard = KeyboardState()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @FocusState private var focusedTabID: UUID?

    /// Open by default at regular width, the way Safari shows its sidebar on
    /// iPad, and remembered once the user takes a side. Compact width never
    /// shows a sidebar, so the preference only ever describes iPad-sized
    /// layouts.
    @AppStorage("Sidebar.visible") private var showsSidebar = true
    @State private var showsSwitcher = false
    @State private var showsSettingsSheet = false

    private var isRegularWidth: Bool { horizontalSizeClass == .regular }

    var body: some View {
        ZStack {
            theme.background(for: colorScheme)
                .ignoresSafeArea()

            HStack(spacing: 0) {
                if isRegularWidth, showsSidebar {
                    SidebarView(tabManager: tabManager)
                        .frame(width: 300)
                        .transition(.move(edge: .leading))
                }
                terminalColumn
            }
        }
        .background(shortcutButtons)
        .onAppear(perform: refocus)
        .onChange(of: tabManager.activeTabID) { _ in refocus() }
        .onChange(of: theme.selection) { _ in
            for tab in tabManager.tabs {
                tab.terminal.controller.setTheme(theme.terminalTheme)
            }
        }
        .fullScreenCover(isPresented: $showsSwitcher, onDismiss: refocus) {
            TabSwitcherView(tabManager: tabManager)
        }
        .sheet(isPresented: $showsSettingsSheet, onDismiss: refocus) {
            SettingsSheet()
        }
        // The switcher, a full-screen cover, presents its own copy of this
        // alert; a covered context cannot present, so this one stands down.
        .closeTabConfirmation(tabManager, isActive: !showsSwitcher)
    }

    private var terminalColumn: some View {
        panes
            .safeAreaInset(edge: .top, spacing: 0) {
                if isRegularWidth {
                    TabStripBar(
                        tabManager: tabManager,
                        showsSidebar: sidebarBinding,
                        onShowSettings: { showsSettingsSheet = true },
                        onShowSwitcher: { showsSwitcher = true }
                    )
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !isRegularWidth, !keyboard.isVisible {
                    BottomBar(
                        tabManager: tabManager,
                        onShowSettings: { showsSettingsSheet = true },
                        onShowSwitcher: { showsSwitcher = true }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
    }

    /// Every tab's surface stays mounted so background sessions keep their
    /// grid and connection; only the active one is visible and hit-testable.
    private var panes: some View {
        ZStack {
            ForEach(tabManager.tabs) { tab in
                let isActive = tab.id == tabManager.activeTabID
                TerminalSurfaceView(context: tab.terminal)
                    .terminalFocused($focusedTabID, equals: tab.id)
                    .overlay {
                        SessionStatusOverlay(store: tab.store)
                    }
                    .opacity(isActive ? 1 : 0)
                    .allowsHitTesting(isActive)
                    .accessibilityHidden(!isActive)
            }
        }
    }

    private var sidebarBinding: Binding<Bool> {
        Binding(
            get: { showsSidebar },
            set: { newValue in
                withAnimation(.easeInOut(duration: 0.25)) {
                    showsSidebar = newValue
                }
            }
        )
    }

    private func refocus() {
        focusedTabID = tabManager.activeTabID
    }

    /// Hardware keyboard shortcuts (iPad with a keyboard, mainly).
    private var shortcutButtons: some View {
        Group {
            Button("New Tab") { tabManager.newTab() }
                .keyboardShortcut("t", modifiers: .command)
            Button("New Window") { Self.requestNewWindow() }
                .keyboardShortcut("n", modifiers: .command)
            Button("Close Tab") {
                if let tab = tabManager.activeTab {
                    tabManager.requestClose(tab)
                }
            }
                .keyboardShortcut("w", modifiers: .command)
            Button("Next Tab") { tabManager.activateAdjacentTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { tabManager.activateAdjacentTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Toggle Sidebar") { sidebarBinding.wrappedValue.toggle() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Show Tabs") { showsSwitcher.toggle() }
                .keyboardShortcut("\\", modifiers: [.command, .shift])
            Button("Settings") { showsSettingsSheet = true }
                .keyboardShortcut(",", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// Opens a new window scene (its own `TabManager`) on devices that
    /// support multiple scenes; no-op elsewhere.
    static func requestNewWindow() {
        guard UIApplication.shared.supportsMultipleScenes else { return }
        UIApplication.shared.requestSceneSessionActivation(
            nil,
            userActivity: nil,
            options: nil,
            errorHandler: nil
        )
    }
}
