//
//  SettingsSheet.swift
//  iGhostty
//

import GhosttyTheme
import SwiftUI

struct SettingsSheet: View {
    @ObservedObject private var theme = AppTheme.shared
    @Environment(\.dismiss) private var dismiss

    /// Read by the daemon when spawning shells. Empty means "let the daemon
    /// pick", which hands the session to `login`.
    @AppStorage("Shell.path") private var shellPath = ""

    var body: some View {
        NavigationView {
            Form {
                appearanceSection
                keyboardSection
                shellSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var appearanceSection: some View {
        Section {
            NavigationLink {
                ThemeListView(slot: .light)
            } label: {
                slotRow(
                    title: "Light Theme",
                    icon: "sun.max.fill",
                    name: theme.selection.lightName ?? Self.defaultLabel("Alabaster")
                )
            }
            NavigationLink {
                ThemeListView(slot: .dark)
            } label: {
                slotRow(
                    title: "Dark Theme",
                    icon: "moon.fill",
                    name: theme.selection.darkName ?? Self.defaultLabel("Afterglow")
                )
            }
            Button("Reset Themes to Defaults") {
                theme.selection = AppTheme.Selection(lightName: nil, darkName: nil)
            }
        } header: {
            Text("Appearance")
        } footer: {
            Text("Themes come from the Ghostty theme catalog and apply to every tab in every window.")
        }
    }

    private var keyboardSection: some View {
        Section {
            NavigationLink {
                KeyboardBarSettingsView()
            } label: {
                Label("Accessory Keys", systemImage: "keyboard")
            }
        } header: {
            Text("Keyboard")
        } footer: {
            Text("Choose and arrange the keys on the bar above the keyboard.")
        }
    }

    private var shellSection: some View {
        Section {
            TextField("/bin/zsh", text: $shellPath)
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .font(.body.monospaced())
        } header: {
            Text("Default Shell")
        } footer: {
            Text(
                """
                A path inside the jailbreak root, like /bin/zsh — not a \
                jbroot-prefixed path, which would break on the next \
                jailbreak. Leave empty to sign in through login.
                """
            )
        }
    }

    private var aboutSection: some View {
        Section("About") {
            HStack {
                Text("Version")
                Spacer()
                Text(Self.versionDescription)
                    .foregroundColor(.secondary)
            }
        }
    }

    /// Theme names are catalog data, so only the marker gets translated.
    private static func defaultLabel(_ name: String) -> String {
        String(
            format: NSLocalizedString("%@ (Default)", comment: "Theme name plus the default marker"),
            name
        )
    }

    private static var versionDescription: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private func slotRow(title: LocalizedStringKey, icon: String, name: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Text(name)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }
}

/// Which appearance slot a picked theme lands in.
enum ThemeSlot {
    case light
    case dark
}

struct ThemeListView: View {
    let slot: ThemeSlot
    @ObservedObject private var theme = AppTheme.shared
    @State private var searchText = ""

    private var themes: [GhosttyThemeDefinition] {
        let all = GhosttyThemeCatalog.allThemes
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !searchText.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var selectedName: String? {
        slot == .light ? theme.selection.lightName : theme.selection.darkName
    }

    var body: some View {
        List(themes) { definition in
            Button(action: { select(definition) }) {
                HStack(spacing: 12) {
                    swatch(for: definition)
                    Text(definition.name)
                        .foregroundColor(.primary)
                    Spacer()
                    if definition.name == selectedName {
                        Image(systemName: "checkmark")
                            .foregroundColor(.accentColor)
                    }
                }
            }
        }
        .searchable(text: $searchText)
        .navigationTitle(slot == .light ? "Light Theme" : "Dark Theme")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func swatch(for definition: GhosttyThemeDefinition) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(hex: definition.background))
                .frame(width: 34, height: 24)
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                }
            Text("$_")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(Color(hex: definition.foreground))
        }
    }

    private func select(_ definition: GhosttyThemeDefinition) {
        switch slot {
        case .light:
            theme.selection.lightName = definition.name
        case .dark:
            theme.selection.darkName = definition.name
        }
    }
}
