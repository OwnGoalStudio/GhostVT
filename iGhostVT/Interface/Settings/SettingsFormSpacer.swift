//
//  SettingsFormSpacer.swift
//  iGhostVT
//

import SwiftUI

/// Breathing room under the last section of a settings page, drawn as
/// nothing: a row in a Form gets a cell background and separator, so the
/// row hides both. Every settings page ends with one.
struct SettingsFormSpacer: View {
    var body: some View {
        Color.clear
            .frame(height: 128)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
    }
}
