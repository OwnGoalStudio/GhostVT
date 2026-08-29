//
//  KeyboardSettingsSection.swift
//  iGhostVT
//

import SwiftUI

/// The accessory bar is a software-keyboard fixture; a Mac has none, so
/// the section is empty there.
struct KeyboardSettingsSection: View {
    var body: some View {
        #if !targetEnvironment(macCatalyst)
            Section {
                NavigationLink {
                    KeyboardBarSettingsView()
                } label: {
                    Label("Accessory Keys", systemImage: "keyboard")
                }
            } header: {
                Text("Keyboard")
                    .font(DS.Font.caption)
            } footer: {
                Text("Choose and arrange the keys on the bar above the keyboard.")
                    .font(DS.Font.detail)
            }
        #else
            EmptyView()
        #endif
    }
}
