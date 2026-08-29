//
//  RootView.swift
//  iGhostVT
//

import GhosttyTerminal
import SwiftUI

/// The window's whole interface. The `TabManager` is owned by the scene
/// delegate; this view (and everything under it) only borrows it, so each
/// window carries independent tabs.
struct RootView: View {
    @ObservedObject var tabManager: TabManager
    /// The presentations the window's menu commands can open.
    @ObservedObject var interface: WindowInterfaceState
    @ObservedObject private var theme = AppTheme.shared
    @StateObject private var keyboard = KeyboardState()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focusedTabID: UUID?

    /// See `SidebarVisibility`; a UserDefaults value so View ▸ Show Sidebar
    /// can flip it from UIKit.
    @AppStorage(SidebarVisibility.key) private var showsSidebar = true

    /// User-dragged sidebar width, remembered like the visibility. The
    /// resize handle clamps it, so a stored value is always presentable.
    @AppStorage("Sidebar.width") private var sidebarWidth = 300.0
    private var isRegularWidth: Bool {
        horizontalSizeClass == .regular
    }

    var body: some View {
        ZStack {
            // The theme's background under everything: on the Mac this is
            // what the sidebar shows, the same colour as the terminal beside
            // it (the sidebar paints nothing of its own there).
            theme.background(for: colorScheme)
                .ignoresSafeArea()

            HStack(spacing: 0) {
                if isRegularWidth, showsSidebar {
                    SidebarView(
                        tabManager: tabManager,
                        showsSidebar: $showsSidebar,
                        onShowSettings: { interface.showsSettingsSheet = true }
                    )
                    .frame(width: sidebarWidth)
                    .overlay(alignment: .trailing) {
                        SidebarResizeHandle(width: $sidebarWidth)
                    }
                    .transition(.move(edge: .leading))
                }
                terminalColumn
            }
            // The animation must hang off the container, keyed on the value:
            // `showsSidebar` is `@AppStorage`, and a UserDefaults-backed write
            // does not reliably land inside a `withAnimation` transaction, so
            // wrapping the setter leaves the transition unanimated.
            .animation(DS.Motion.smooth, value: showsSidebar)
            // The title bar is hidden and its strip is ours: the top bar
            // rides the window's edge, the sidebar clears the traffic lights
            // itself.
            .catalystIgnoresTitleBar()
        }
        .onAppear(perform: refocus)
        .onChange(of: tabManager.activeTabID) { _ in refocus() }
        // Backgrounding resigns the surface's first responder (which clears
        // the FocusState through the bridge), so coming back needs the focus
        // handed out again — typing should work the moment the app does.
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            refocus()
        }
        .onChange(of: theme.selection) { _ in
            for tab in tabManager.tabs {
                tab.terminal.controller.setTheme(theme.terminalTheme)
            }
        }
        .onReceive(KeyboardBarStore.shared.$entries) { _ in
            for tab in tabManager.tabs {
                KeyboardBarStore.shared.apply(to: tab.terminal)
            }
        }
        // The cards' pictures are taken here, on the flip that opens the
        // cover, whichever control flipped it (the bar's button, the menu
        // command): the panes are still on screen at this point, and a
        // capture from inside the cover would be too late for any card the
        // grid lays out after the transition has removed them.
        .onChange(of: interface.showsSwitcher) { shows in
            guard shows else { return }
            tabManager.capturePreviews()
        }
        .fullScreenCover(isPresented: $interface.showsSwitcher, onDismiss: refocus) {
            TabSwitcherView(tabManager: tabManager)
        }
        .sheet(isPresented: $interface.showsSettingsSheet, onDismiss: refocus) {
            SettingsSheet()
        }
        .sheet(item: $tabManager.selectionRequest, onDismiss: refocus) { box in
            TerminalSelectionSheet(
                text: box.request.text,
                anchorRange: box.request.anchorRange
            )
        }
        // One copy for the whole window: each confirmation presents as an
        // `AlertViewController` on the front-most context, so it lands above
        // the switcher's cover too.
        .closeTabConfirmation(tabManager)
        .clipboardConfirmation(tabManager)
        .relocationPrompt(MacLaunchAgent.shared)
    }

    private var terminalColumn: some View {
        panes
            .safeAreaInset(edge: .top, spacing: 0) {
                if isRegularWidth {
                    TabStripBar(
                        tabManager: tabManager,
                        showsSidebar: $showsSidebar
                    )
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // The bar stays up with no tabs: its `+` is the only way to
                // open one at this width. The title capsule leaves on its
                // own with the tab.
                if !isRegularWidth, !keyboard.isVisible {
                    BottomBar(
                        tabManager: tabManager,
                        onShowSettings: { interface.showsSettingsSheet = true },
                        onShowSwitcher: { interface.showsSwitcher = true }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .catalystColumnBackground(theme.background(for: colorScheme))
    }

    /// Every tab's surface stays mounted so background sessions keep their
    /// grid and connection; only the active one is visible and hit-testable.
    /// Insertions and removals ride the `TabManager.tabTransition` animation;
    /// switching tabs stays an instant opacity flip.
    private var panes: some View {
        ZStack {
            if tabManager.tabs.isEmpty {
                EmptyTabsView()
                    .transition(.opacity)
            }
            ForEach(tabManager.tabs) { tab in
                TerminalPane(
                    tab: tab,
                    isActive: tab.id == tabManager.activeTabID,
                    focusedTabID: $focusedTabID,
                    onCloseTab: { tabManager.requestClose(tab) },
                    onLockChange: refocus
                )
                .transition(.asymmetric(
                    insertion: .opacity,
                    removal: .scale(scale: 0.92).combined(with: .opacity)
                ))
            }
        }
    }

    private func refocus() {
        // A locked tab must not hold keyboard focus: its surface ignores
        // touches, and hardware keys reaching it anyway would defeat the
        // lock.
        guard let tab = tabManager.activeTab, !tab.isLocked else {
            focusedTabID = nil
            return
        }
        focusedTabID = tab.id
        // FocusState alone is best-effort — SwiftUI can reset it to nil
        // before the bridge acts, leaving the previous tab's surface holding
        // first responder and eating every hardware key. Hand focus over
        // imperatively so a tab switch always lands on the active terminal.
        tab.terminal.requestFocus()
    }
}

/// One tab's surface with its per-tab chrome. A separate view so the lock
/// state is actually observed: the `ForEach` in `RootView` does not watch
/// individual tabs, and a lock toggled from a context menu would otherwise
/// change nothing until an unrelated redraw.
private struct TerminalPane: View {
    @ObservedObject var tab: TerminalTab
    let isActive: Bool
    let focusedTabID: FocusState<UUID?>.Binding
    let onCloseTab: () -> Void
    let onLockChange: () -> Void

    var body: some View {
        TerminalSurfaceView(context: tab.terminal)
            .terminalFocused(focusedTabID, equals: tab.id)
            .overlay {
                SessionStatusOverlay(store: tab.store, onCloseTab: onCloseTab)
            }
            .overlay(alignment: .topTrailing) {
                if tab.isLocked {
                    Label("Locked", systemImage: "lock.fill")
                        .font(DS.Font.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, DS.Padding.m)
                        .padding(.vertical, DS.Padding.xs)
                        .background(.thinMaterial, in: Capsule())
                        .padding(DS.Padding.m)
                        .transition(.opacity)
                }
            }
            .opacity(isActive ? 1 : 0)
            // The lock itself is not modeled here: `LockableTerminalView`
            // refuses hit testing and first responder at the view, so every
            // input path closes in one place while output keeps rendering.
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
            .onChange(of: tab.isLocked) { _ in onLockChange() }
    }
}

private extension View {
    @ViewBuilder
    func catalystIgnoresTitleBar() -> some View {
        #if targetEnvironment(macCatalyst)
            ignoresSafeArea(.container, edges: .top)
        #else
            self
        #endif
    }

    /// The Mac paints the theme under the terminal column only — the
    /// sidebar beside it shows the window's blur.
    @ViewBuilder
    func catalystColumnBackground(_ color: Color) -> some View {
        #if targetEnvironment(macCatalyst)
            background(color.ignoresSafeArea())
        #else
            self
        #endif
    }
}
