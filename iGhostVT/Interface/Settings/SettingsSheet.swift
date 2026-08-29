//
//  SettingsSheet.swift
//  iGhostVT
//

import GhosttyTerminal
import GhosttyTheme
import SwiftUI

struct SettingsSheet: View {
    @ObservedObject private var theme = AppTheme.shared
    @Environment(\.dismiss) private var dismiss

    /// Steps around the platform's own text size; see `InterfaceTextSize`.
    @AppStorage(InterfaceTextSize.key) private var interfaceTextStep = 0

    /// Read by `TerminalTab` when a surface is made; open tabs keep theirs.
    @AppStorage(TerminalFontSize.key) private var terminalFontSize = TerminalFontSize.default

    /// Read by AppDelegate when the app quits; see `SessionKeepAlive`.
    @AppStorage(SessionKeepAlive.key) private var keepAlive = true

    /// Read by `TabManager` when a session ends; see `SessionAutoClose`.
    @AppStorage(SessionAutoClose.key) private var autoCloseTabs = false

    var body: some View {
        NavigationView {
            Form {
                appearanceSection
                textSizeSection
                keyboardSection
                sessionsSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .doneToolbarItem { dismiss() }
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
                    name: theme.selection.lightName ?? Self.defaultLabel(AppTheme.defaultLightName)
                )
            }
            NavigationLink {
                ThemeListView(slot: .dark)
            } label: {
                slotRow(
                    title: "Dark Theme",
                    icon: "moon.fill",
                    name: theme.selection.darkName ?? Self.defaultLabel(AppTheme.defaultDarkName)
                )
            }
        } header: {
            Text("Appearance")
                .font(DS.Font.caption)
        } footer: {
            Text("Themes come from the Ghostty theme catalog and apply to every tab in every window.")
                .font(DS.Font.detail)
        }
    }

    /// One stepper per kind of text: the terminal's, a point size the
    /// surface takes as it is, and the chrome's, a multiplier on every
    /// `DS.Font` role. The terminal comes first — it is what people came to
    /// resize; the sheet's own rows carry the roles, so the second stepper
    /// shows its effect as it goes.
    private var textSizeSection: some View {
        Section {
            Stepper(value: $terminalFontSize, in: TerminalFontSize.range) {
                slotRow(
                    title: "Terminal",
                    icon: "terminal",
                    name: String.localizedStringWithFormat(
                        NSLocalizedString("%lld pt", comment: "A font size in points"),
                        terminalFontSize
                    )
                )
            }
            Stepper(value: $interfaceTextStep, in: InterfaceTextSize.steps) {
                slotRow(title: "Interface", icon: "textformat.size", name: interfaceScaleDescription)
            }
        } header: {
            Text("Text Size")
                .font(DS.Font.caption)
        } footer: {
            Text(
                """
                New terminals open at the terminal size; a tab that is already \
                open keeps the size it was zoomed to. The interface size scales \
                every label and control.
                """
            )
                .font(DS.Font.detail)
        }
    }

    /// The multiplier as a percentage; a number needs no translation.
    private var interfaceScaleDescription: String {
        let percent = Int((InterfaceTextSize.scale(step: interfaceTextStep) * 100).rounded())
        return "\(percent)%"
    }

    /// The accessory bar is a software-keyboard fixture; a Mac has none.
    @ViewBuilder
    private var keyboardSection: some View {
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
        #endif
    }

    private var sessionsSection: some View {
        Section {
            Toggle("Keep Sessions Running", isOn: $keepAlive)
            Toggle("Auto-Close Tabs", isOn: $autoCloseTabs)
        } header: {
            Text("Sessions")
                .font(DS.Font.caption)
        } footer: {
            VStack(alignment: .leading, spacing: DS.Padding.s) {
                Text(
                    """
                    Sessions with a program running keep going after the app quits \
                    and come back on the next launch; a shell sitting at its prompt \
                    closes. Turn this off to close every session when the app quits.
                    """
                )
                Text(
                    """
                    With Auto-Close Tabs on, a tab closes by itself when its \
                    session ends instead of asking whether to keep it.
                    """
                )
            }
            .font(DS.Font.detail)
        }
    }

    /// Advanced sits here, at the end, and not among the everyday sections:
    /// the shell path, the Mac helper, and the keystroke log are settings
    /// most people never need, and the ones who do will look past Version.
    private var aboutSection: some View {
        Section {
            HStack {
                Text("Version")
                Spacer()
                Text(Self.versionDescription)
                    .foregroundColor(.secondary)
            }
            NavigationLink {
                AdvancedSettingsView()
            } label: {
                Text("Advanced")
            }
        } header: {
            Text("About")
                .font(DS.Font.caption)
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
                HStack(spacing: DS.Padding.m) {
                    swatch(for: definition)
                    Text(definition.name)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Spacer(minLength: DS.Padding.s)
                    paletteStrip(for: definition)
                    // Every row keeps the checkmark's slot, so the strips
                    // stay in one column whichever row is selected.
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                        .opacity(definition.name == selectedName ? 1 : 0)
                        .accessibilityHidden(definition.name != selectedName)
                }
            }
        }
        .searchable(text: $searchText)
        .navigationTitle(slot == .light ? "Light Theme" : "Dark Theme")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func swatch(for definition: GhosttyThemeDefinition) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                .fill(Color(hex: definition.background))
                .frame(width: 34, height: 24)
                .overlay {
                    RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                }
            Text(verbatim: "$_")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(Color(hex: definition.foreground))
        }
    }

    /// The eight base ANSI colors (0–7) as one segmented strip, so a theme's
    /// character shows without opening it. A missing entry falls back to the
    /// foreground rather than leaving a gap, so every strip has the same width.
    private func paletteStrip(for definition: GhosttyThemeDefinition) -> some View {
        HStack(spacing: 0) {
            ForEach(0 ..< 8, id: \.self) { index in
                Color(hex: definition.palette[index] ?? definition.foreground)
                    .frame(width: 7)
            }
        }
        .frame(height: 14)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
        }
        .accessibilityHidden(true)
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

private extension View {
    /// The sheet's one confirming control: the toolbar's own prominent
    /// button, left at the size the toolbar gives it. iOS 26 draws it as its
    /// own glass disc; earlier systems fill it with the accent. Two toolbars
    /// rather than one conditional item: `ToolbarContent` cannot branch on
    /// iOS 15.
    @ViewBuilder
    func doneToolbarItem(action: @escaping () -> Void) -> some View {
        if #available(iOS 26.0, *) {
            toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    DoneButton(action: action)
                        .buttonStyle(.glassProminent)
                }
            }
        } else {
            toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    DoneButton(action: action)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

private struct DoneButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "checkmark")
        }
        .accessibilityLabel("Done")
    }
}
