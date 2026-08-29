//
//  SettingsSheet.swift
//  iGhostVT
//

import GhosttyTerminal
import GhosttyTheme
import SwiftUI

struct SettingsSheet: View {
    @ObservedObject private var theme = AppTheme.shared
    @ObservedObject private var agent = MacLaunchAgent.shared
    @Environment(\.dismiss) private var dismiss

    /// Read by the daemon when spawning shells. Empty means "let the daemon
    /// pick", which hands the session to `login`.
    @AppStorage("Shell.path") private var shellPath = ""

    /// Read by AppDelegate when the app quits; see `SessionKeepAlive`.
    @AppStorage(SessionKeepAlive.key) private var keepAlive = true

    /// Mirrored by AppDelegate at launch; toggling applies immediately.
    @AppStorage("Debug.verboseTerminalLog") private var verboseTerminalLog = false

    var body: some View {
        NavigationView {
            Form {
                appearanceSection
                keyboardSection
                shellSection
                sessionsSection
                terminalHelperSection
                debugSection
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
            Button("Reset Themes") {
                theme.selection = AppTheme.Selection(lightName: nil, darkName: nil)
            }
        } header: {
            Text("Appearance")
        } footer: {
            Text("Themes come from the Ghostty theme catalog and apply to every tab in every window.")
        }
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
            } footer: {
                Text("Choose and arrange the keys on the bar above the keyboard.")
            }
        #endif
    }

    private var shellSection: some View {
        Section {
            // A literal example, not copy: the StringProtocol overload keeps
            // it out of the string catalog.
            TextField(Self.shellPlaceholder, text: $shellPath)
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .font(DS.Font.mono)
        } header: {
            Text("Default Shell")
        } footer: {
            Text(
                """
                The program every new terminal runs, for example /bin/zsh. \
                Use a plain path; one that includes the jailbreak root stops \
                working after the next jailbreak. Leave this empty to use the \
                default login shell.
                """
            )
        }
    }

    private static let shellPlaceholder = "/bin/zsh"

    private var sessionsSection: some View {
        Section {
            Toggle("Keep Sessions Running", isOn: $keepAlive)
        } header: {
            Text("Sessions")
        } footer: {
            Text(
                """
                Sessions keep running after the app quits and come back on the \
                next launch. Turn this off to close every session when the app \
                quits.
                """
            )
        }
    }

    /// The Mac's only install step, and its only uninstall step.
    ///
    /// Dragging the app to the Trash does not remove a Login Items entry —
    /// macOS keeps it, pointing at a bundle that no longer exists, and the
    /// person who wants it gone has no obvious way back to it. This is that
    /// way back. It also surfaces what `unregister()` returns, because a
    /// silent failure here leaves a background agent running with nothing on
    /// screen admitting it.
    @ViewBuilder
    private var terminalHelperSection: some View {
        #if targetEnvironment(macCatalyst)
            if agent.status != .unsupported {
                Section {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(agentStatusDescription)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    if agent.isRegistered {
                        Button("Turn Off Helper", role: .destructive) { agent.deactivate() }
                    } else {
                        Button("Turn On Helper") { agent.activate() }
                    }
                    Button("Open Login Items") { agent.openLoginItemsSettings() }
                } header: {
                    Text("Terminal Helper")
                } footer: {
                    Text(
                        """
                        iGhostVT opens terminals through a helper that runs in \
                        the background, so sessions keep going while the app is \
                        closed. Turning it off ends every session and removes \
                        iGhostVT from Login Items.
                        """
                    )
                }
            }
        #endif
    }

    private var agentStatusDescription: String {
        switch agent.status {
        case .enabled:
            String(localized: "On")
        case .needsApproval:
            String(localized: "Waiting for Approval")
        case .needsRelocation:
            String(localized: "Move to Applications")
        case .notRegistered:
            String(localized: "Off")
        case let .failed(reason):
            reason
        case .notApplicable, .unsupported:
            String(localized: "Not Available")
        }
    }

    private var debugSection: some View {
        Section {
            Toggle("Verbose Terminal Log", isOn: $verboseTerminalLog)
                .onChange(of: verboseTerminalLog) { enabled in
                    if enabled {
                        TerminalDebugLog.enable(.standard)
                    } else {
                        TerminalDebugLog.enable([.lifecycle, .metrics])
                    }
                }
        } header: {
            Text("Debugging")
        } footer: {
            Text(
                """
                Writes detailed terminal activity to the system log, \
                including every keystroke, while this is on.
                """
            )
        }
    }

    private var aboutSection: some View {
        Section {
            HStack {
                Text("Version")
                Spacer()
                Text(Self.versionDescription)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("About")
        } footer: {
            Text(Self.ghosttyConfigPath)
                .font(DS.Font.monoCaption)
                .textSelection(.enabled)
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

    /// Where libghostty is reading its settings from.
    ///
    /// libghostty has no API to take configuration from memory —
    /// `ghostty_config_load_file` is the only door — so the terminal's colors,
    /// font, and keybinds reach it as a file rendered into the temporary
    /// directory on every reconfigure. On a jailbroken install that write is
    /// exactly what fails when the bundle is signed without the entitlements
    /// its bootstrap demands, and the symptom (a terminal stuck on
    /// "Starting…") says nothing about a path, so the path belongs on screen.
    private static var ghosttyConfigPath: String {
        let directory = FileManager.default.temporaryDirectory
        let rendered = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ))?
            .filter { $0.lastPathComponent.hasPrefix("ghostty-config-") }
            .max { left, right in
                let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return leftDate < rightDate
            }
        guard let rendered else {
            return String.localizedStringWithFormat(
                NSLocalizedString(
                    "No configuration file yet. It will be saved to %@.",
                    comment: "Settings footer when the rendered ghostty config is missing; %@ is a directory path"
                ),
                directory.path
            )
        }
        return rendered.path
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

    private func select(_ definition: GhosttyThemeDefinition) {
        switch slot {
        case .light:
            theme.selection.lightName = definition.name
        case .dark:
            theme.selection.darkName = definition.name
        }
    }
}
