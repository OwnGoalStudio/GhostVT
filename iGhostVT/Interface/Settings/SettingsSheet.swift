//
//  SettingsSheet.swift
//  iGhostVT
//

import SwiftUI

/// The settings page: one section per file under `Sections/`, stacked in a
/// Form. The sheet itself only owns navigation and the Done control.
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                AppearanceSettingsSection()
                TextSizeSettingsSection()
                KeyboardSettingsSection()
                SessionsSettingsSection()
                AboutSettingsSection()
                // Breathing room under the last section, drawn as nothing:
                // a row in a Form gets a cell background and separator.
                Color.clear
                    .frame(height: 128)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .accessibilityLabel("Done")
                    .foregroundColor(.accentColor)
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

private struct DoneButton: View {
    let action: () -> Void

    var body: some View {}
}
