//
//  KeyboardSettingsSection.swift
//  iGhostVT
//

import SwiftUI

/// Shortcuts on every platform; the accessory bar is a software-keyboard
/// fixture, and a Mac has none.
struct KeyboardSettingsSection: View {
    var body: some View {
        Section {
            NavigationLink {
                ShortcutsSettingsView()
            } label: {
                Label("Shortcuts", systemImage: "command")
            }
            #if !targetEnvironment(macCatalyst)
                NavigationLink {
                    KeyboardBarSettingsView()
                } label: {
                    Label("Accessory Keys", systemImage: "keyboard")
                }
            #endif
        } header: {
            Text("Keyboard")
                .font(DS.Font.caption)
        } footer: {
            #if !targetEnvironment(macCatalyst)
                Text("Choose and arrange the keys on the bar above the keyboard.")
                    .font(DS.Font.detail)
            #endif
        }
    }
}
