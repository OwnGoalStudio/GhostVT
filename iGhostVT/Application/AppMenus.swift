//
//  AppMenus.swift
//  iGhostVT
//

import UIKit

/// The actions the main menu dispatches, resolved through the responder
/// chain. `TerminalWindow` implements them for its own tabs, so a command
/// always lands in the window that has focus — the Mac's menu bar and the
/// iPad's hold-⌘ overlay both read this one list.
@MainActor
@objc protocol AppCommandResponder {
    func newTab(_ sender: Any?)
    func newWindow(_ sender: Any?)
    func closeTab(_ sender: Any?)
    func closeWindow(_ sender: Any?)
    func exportTabText(_ sender: Any?)
    func showSettings(_ sender: Any?)
    func toggleTabSidebar(_ sender: Any?)
    func toggleTabSwitcher(_ sender: Any?)
    func increaseFontSize(_ sender: Any?)
    func decreaseFontSize(_ sender: Any?)
    func resetFontSize(_ sender: Any?)
    func clearScreen(_ sender: Any?)
    func showNextTab(_ sender: Any?)
    func showPreviousTab(_ sender: Any?)
    /// `sender` is a `UIKeyCommand` whose `propertyList` is the tab index;
    /// `AppMenus.lastTabIndex` means the last tab, whatever the count.
    func selectTab(_ sender: Any?)
    func toggleTabLock(_ sender: Any?)
    func toggleKeyboardLock(_ sender: Any?)
}

/// The app's menu bar, following the platform's own bindings: Terminal.app
/// and Safari for tabs and windows, Ghostty for the terminal itself.
///
/// Where two conventions coexist, both keys work and the menu shows the one
/// Apple's apps print — ⌘T for New Tab with ⌘N as a hidden alias, ⌃Tab for
/// Next Tab with ⇧⌘] hidden, ⌃⌘S (the AppKit standard) for the sidebar with
/// Safari's ⇧⌘L hidden. A hidden command still fires; it is only kept out of
/// the menu and the overlay so each action reads with a single key.
enum AppMenus {
    /// `propertyList` of the Go to Tab command that means "the last tab".
    static let lastTabIndex = -1

    static func install(into builder: UIMenuBuilder) {
        installFileMenu(into: builder)
        installSettings(into: builder)
        installViewMenu(into: builder)
        installWindowMenu(into: builder)
    }

    // MARK: - File

    /// The system File menu's New (⌘N) opens a window and its Close (⌘W)
    /// closes one; in a tabbed terminal both keys belong to the tab.
    private static func installFileMenu(into builder: UIMenuBuilder) {
        for identifier in [UIMenu.Identifier.newScene, .close] where builder.menu(for: identifier) != nil {
            builder.remove(menu: identifier)
        }

        let newGroup = UIMenu(
            title: "",
            identifier: UIMenu.Identifier("wiki.qaq.iGhostVT.file.new"),
            options: .displayInline,
            children: [
                command(
                    L("New Tab", "Menu item: opens a new terminal tab"),
                    #selector(AppCommandResponder.newTab(_:)),
                    "t", .command
                ),
                hidden(#selector(AppCommandResponder.newTab(_:)), "n", .command),
                command(
                    L("New Window", "Menu item: opens a new window"),
                    #selector(AppCommandResponder.newWindow(_:)),
                    "n", [.command, .shift]
                ),
            ]
        )
        let closeGroup = UIMenu(
            title: "",
            identifier: UIMenu.Identifier("wiki.qaq.iGhostVT.file.close"),
            options: .displayInline,
            children: [
                command(
                    L("Close Tab", "Menu item: closes the active terminal tab"),
                    #selector(AppCommandResponder.closeTab(_:)),
                    "w", .command
                ),
                command(
                    L("Close Window", "Menu item: closes the window"),
                    #selector(AppCommandResponder.closeWindow(_:)),
                    "w", [.command, .shift]
                ),
            ]
        )
        let exportGroup = UIMenu(
            title: "",
            identifier: UIMenu.Identifier("wiki.qaq.iGhostVT.file.export"),
            options: .displayInline,
            children: [
                command(
                    L("Export Text…", "Menu item: shares the visible terminal text as a file"),
                    #selector(AppCommandResponder.exportTabText(_:)),
                    "s", [.command, .shift]
                ),
            ]
        )
        builder.insertChild(newGroup, atStartOfMenu: .file)
        builder.insertSibling(closeGroup, afterMenu: newGroup.identifier)
        builder.insertSibling(exportGroup, afterMenu: closeGroup.identifier)
    }

    // MARK: - Settings

    /// ⌘, in the application menu, where every Mac app keeps it.
    private static func installSettings(into builder: UIMenuBuilder) {
        let settings = UIMenu(
            title: "",
            identifier: UIMenu.Identifier("wiki.qaq.iGhostVT.settings"),
            options: .displayInline,
            children: [
                // Keyed apart from the "Settings" title: two keys with the
                // same words collide in the catalog's generated symbols.
                command(
                    L("Settings… (menu)", "Menu item: opens the app's settings; the English text is “Settings…”"),
                    #selector(AppCommandResponder.showSettings(_:)),
                    ",", .command
                ),
            ]
        )
        if builder.menu(for: .preferences) != nil {
            builder.replace(menu: .preferences, with: settings)
        } else if builder.menu(for: .about) != nil {
            builder.insertSibling(settings, afterMenu: .about)
        } else {
            builder.insertChild(settings, atStartOfMenu: .application)
        }
    }

    // MARK: - View

    private static func installViewMenu(into builder: UIMenuBuilder) {
        // Catalyst's own Show Sidebar item targets a split view controller
        // this app does not have; ours takes its place and its key.
        if builder.menu(for: .sidebar) != nil {
            builder.remove(menu: .sidebar)
        }
        let chrome = UIMenu(
            title: "",
            identifier: UIMenu.Identifier("wiki.qaq.iGhostVT.view.chrome"),
            options: .displayInline,
            children: [
                // The title is rewritten by `validate(_:)` to say Show or Hide.
                command(
                    L("Show Sidebar", "Menu item: shows the tab sidebar"),
                    #selector(AppCommandResponder.toggleTabSidebar(_:)),
                    "s", [.command, .control]
                ),
                hidden(#selector(AppCommandResponder.toggleTabSidebar(_:)), "l", [.command, .shift]),
                command(
                    L("Show All Tabs", "Menu item: opens the tab overview"),
                    #selector(AppCommandResponder.toggleTabSwitcher(_:)),
                    "\\", [.command, .shift]
                ),
            ]
        )
        let text = UIMenu(
            title: "",
            identifier: UIMenu.Identifier("wiki.qaq.iGhostVT.view.text"),
            options: .displayInline,
            children: [
                command(
                    L("Bigger", "Menu item: increases the terminal font size"),
                    #selector(AppCommandResponder.increaseFontSize(_:)),
                    "+", .command
                ),
                hidden(#selector(AppCommandResponder.increaseFontSize(_:)), "=", .command),
                command(
                    L("Smaller", "Menu item: decreases the terminal font size"),
                    #selector(AppCommandResponder.decreaseFontSize(_:)),
                    "-", .command
                ),
                command(
                    L("Actual Size", "Menu item: resets the terminal font size"),
                    #selector(AppCommandResponder.resetFontSize(_:)),
                    "0", .command
                ),
            ]
        )
        let screen = UIMenu(
            title: "",
            identifier: UIMenu.Identifier("wiki.qaq.iGhostVT.view.screen"),
            options: .displayInline,
            children: [
                command(
                    L("Clear Screen", "Menu item: clears the terminal screen and scrollback"),
                    #selector(AppCommandResponder.clearScreen(_:)),
                    "k", .command
                ),
            ]
        )
        builder.insertChild(chrome, atStartOfMenu: .view)
        builder.insertSibling(text, afterMenu: chrome.identifier)
        builder.insertSibling(screen, afterMenu: text.identifier)
    }

    // MARK: - Window

    private static func installWindowMenu(into builder: UIMenuBuilder) {
        var gotoChildren: [UIMenuElement] = (1 ... 8).map { number in
            command(
                String.localizedStringWithFormat(
                    L("Tab %d", "Menu item: switches to the tab at this position; %d is the position"),
                    number
                ),
                #selector(AppCommandResponder.selectTab(_:)),
                String(number), .command,
                propertyList: number - 1
            )
        }
        gotoChildren.append(command(
            L("Last Tab", "Menu item: switches to the last tab"),
            #selector(AppCommandResponder.selectTab(_:)),
            "9", .command,
            propertyList: lastTabIndex
        ))
        let navigation = UIMenu(
            title: "",
            identifier: UIMenu.Identifier("wiki.qaq.iGhostVT.window.tabs"),
            options: .displayInline,
            children: [
                command(
                    L("Show Previous Tab", "Menu item: activates the tab before the current one"),
                    #selector(AppCommandResponder.showPreviousTab(_:)),
                    "\t", [.control, .shift]
                ),
                hidden(#selector(AppCommandResponder.showPreviousTab(_:)), "[", [.command, .shift]),
                command(
                    L("Show Next Tab", "Menu item: activates the tab after the current one"),
                    #selector(AppCommandResponder.showNextTab(_:)),
                    "\t", .control
                ),
                hidden(#selector(AppCommandResponder.showNextTab(_:)), "]", [.command, .shift]),
                UIMenu(
                    title: L("Go to Tab", "Menu: submenu listing tab positions"),
                    identifier: UIMenu.Identifier("wiki.qaq.iGhostVT.window.goto"),
                    children: gotoChildren
                ),
            ]
        )
        let locks = UIMenu(
            title: "",
            identifier: UIMenu.Identifier("wiki.qaq.iGhostVT.window.locks"),
            options: .displayInline,
            children: [
                command(
                    L("Lock Tab", "Menu item: toggles the tab's input lock"),
                    #selector(AppCommandResponder.toggleTabLock(_:)),
                    "l", [.command, .alternate]
                ),
                command(
                    L("Lock Keyboard", "Menu item: toggles the tab's keyboard lock"),
                    #selector(AppCommandResponder.toggleKeyboardLock(_:)),
                    "k", [.command, .alternate]
                ),
            ]
        )
        builder.insertChild(navigation, atStartOfMenu: .window)
        builder.insertSibling(locks, afterMenu: navigation.identifier)
    }

    // MARK: - Helpers

    private static func L(_ key: String, _ comment: String) -> String {
        NSLocalizedString(key, comment: comment)
    }

    private static func command(
        _ title: String,
        _ action: Selector,
        _ input: String,
        _ modifiers: UIKeyModifierFlags,
        propertyList: Int? = nil
    ) -> UIKeyCommand {
        UIKeyCommand(
            title: title,
            action: action,
            input: input,
            modifierFlags: modifiers,
            propertyList: propertyList
        )
    }

    /// An alias key: fires the same action, never listed.
    private static func hidden(
        _ action: Selector,
        _ input: String,
        _ modifiers: UIKeyModifierFlags
    ) -> UIKeyCommand {
        UIKeyCommand(
            title: "",
            action: action,
            input: input,
            modifierFlags: modifiers,
            attributes: .hidden
        )
    }
}
