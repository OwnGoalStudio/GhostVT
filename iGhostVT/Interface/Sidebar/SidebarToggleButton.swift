//
//  SidebarToggleButton.swift
//  iGhostVT
//

import SwiftUI

/// The one control that shows and hides the sidebar. It lives on whichever
/// side of the seam the sidebar is not: in the top bar's leading end while
/// the sidebar is hidden, and at the trailing end of the sidebar's top strip
/// — beside the separator — while it is open, so the button sits where the
/// edge it moves will be.
struct SidebarToggleButton: View {
    @Binding var showsSidebar: Bool

    var body: some View {
        Button(action: { showsSidebar.toggle() }) {
            Image(systemName: "sidebar.leading")
                .font(DS.Font.control)
                .frame(width: TabStripBar.controlSize, height: TabStripBar.controlSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Toggle Sidebar")
    }
}
