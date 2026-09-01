//
//  SettingsSheet.swift
//  iGhostVT
//

import SwiftUI

/// The settings page: one section per file under `Sections/`, stacked in a
/// Form. The sheet itself only owns navigation and the Done control.
///
/// Presented through `settingsPresentation` — a sheet on iOS, the glass
/// panel on the Mac. The panel is a UIKit presentation, so it hands in its
/// own `onDone`; a sheet leaves it nil and Done is the environment's dismiss.
struct SettingsSheet: View {
    var onDone: (() -> Void)?
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
                        if let onDone {
                            onDone()
                        } else {
                            dismiss()
                        }
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
