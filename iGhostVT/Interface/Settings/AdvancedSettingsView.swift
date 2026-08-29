//
//  AdvancedSettingsView.swift
//  iGhostVT
//

import GhosttyTerminal
import SwiftUI

/// The settings a regular user never needs, off the main sheet so they
/// don't read as things to fill in: the shell every terminal runs, the
/// Mac's background helper, and the keystroke-level log.
struct AdvancedSettingsView: View {
    @ObservedObject private var agent = MacLaunchAgent.shared

    /// Read by the daemon when spawning shells. Empty means "let the daemon
    /// pick", which hands the session to `login`.
    @AppStorage("Shell.path") private var shellPath = ""

    /// Mirrored by AppDelegate at launch; toggling applies immediately.
    @AppStorage("Debug.verboseTerminalLog") private var verboseTerminalLog = false

    var body: some View {
        Form {
            shellSection
            terminalHelperSection
            debugSection
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var shellSection: some View {
        Section {
            // A literal example, not copy: the StringProtocol overload keeps
            // it out of the string catalog.
            TextField(Self.shellPlaceholder, text: $shellPath)
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
        } header: {
            Text("Default Shell")
                .font(DS.Font.caption)
        } footer: {
            // The jailbreak-root caveat is a device matter; a Mac has no
            // bootstrap to prefix a path with.
            #if targetEnvironment(macCatalyst)
                Text(
                    """
                    The program every new terminal runs, for example /bin/zsh. \
                    Leave this empty to use your login shell.
                    """
                )
                .font(DS.Font.detail)
            #else
                Text(
                    """
                    The program every new terminal runs, for example /bin/zsh. \
                    Leave this empty to use the default login shell. Use a plain \
                    path; one that includes the jailbreak root stops working after \
                    the next jailbreak.
                    """
                )
                .font(DS.Font.detail)
            #endif
        }
    }

    private static let shellPlaceholder = "/bin/zsh"

    /// Read-only: the helper registers itself on every launch, and the one
    /// control that removes it is the system's — Login Items in System
    /// Settings — so the footer points there instead of duplicating it.
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
                } header: {
                    Text("Terminal Helper")
                        .font(DS.Font.caption)
                } footer: {
                    Text(
                        """
                        iGhostVT opens terminals through a helper that runs in \
                        the background, so sessions keep going while the app is \
                        closed. It is set up automatically. To remove it, turn \
                        iGhostVT off under Login Items in System Settings.
                        """
                    )
                    .font(DS.Font.detail)
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
        case .brokenInstallation:
            String(localized: "Broken Installation")
        case let .failed(reason):
            reason
        case .notApplicable, .unsupported:
            String(localized: "Not Available")
        }
    }

    private var debugSection: some View {
        Section {
            Toggle("Detailed Terminal Log", isOn: $verboseTerminalLog)
                .onChange(of: verboseTerminalLog) { enabled in
                    if enabled {
                        TerminalDebugLog.enable(.standard)
                    } else {
                        TerminalDebugLog.enable([.lifecycle, .metrics])
                    }
                }
        } header: {
            Text("Debugging")
                .font(DS.Font.caption)
        } footer: {
            Text(
                """
                Writes detailed terminal activity to the system log, \
                including every keystroke, while this is on.
                """
            )
            .font(DS.Font.detail)
        }
    }
}
