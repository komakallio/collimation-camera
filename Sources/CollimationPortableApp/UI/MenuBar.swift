import CImGui
import CollimationCore
import CollimationUI
import Foundation

/// The main menu bar, built from `CommandCatalog`.
///
/// Same source as the macOS menus, so a shortcut or an enablement rule exists
/// in exactly one place (§12.1 item 5).
@MainActor
enum MenuBar {
    /// Height in window coordinates, so the live region can start below it.
    nonisolated(unsafe) static var height: Double = 0

    /// Set by File ▸ Quit or its shortcut. The loop reads it.
    nonisolated(unsafe) static var quitRequested = false

    /// ⌘Q on macOS, Ctrl+Q on Windows, the same way `Shortcut` renders every
    /// other one.
    static let quitShortcut = Shortcut.primary("q")

    static func draw(engine: CollimationEngine, host: any UIHost) {
        guard igBeginMainMenuBar() else { return }
        height = Double(igGetWindowHeight())

        // Quit is not a `CommandCatalog` entry: it acts on the process, not on
        // the engine, and on macOS the SwiftUI app gets it from the system app
        // menu instead. This window is the only place it can live, and without
        // it the app can only be closed from the title bar.
        if "File".withCString({ igBeginMenu($0, true) }) {
            let clicked = "Quit".withCString { label in
                MenuBar.quitShortcut.displayString.withCString { shortcut in
                    igMenuItem_Bool(label, shortcut, false, true)
                }
            }
            if clicked { quitRequested = true }
            igEndMenu()
        }

        for menu in CommandMenu.allCases {
            let commands = CommandCatalog.commands(in: menu, engine: engine)
            guard !commands.isEmpty else { continue }
            let opened = menu.title.withCString { igBeginMenu($0, true) }
            guard opened else { continue }
            for command in commands {
                item(command, engine: engine, host: host)
            }
            igEndMenu()
        }
        igEndMainMenuBar()
    }

    private static func item(_ command: Command, engine: CollimationEngine, host: any UIHost) {
        let label = command.title(engine)
        let shortcut = command.shortcuts.first?.displayString ?? ""
        let enabled = command.isEnabled(engine)

        var selected = false
        if case .toggle(let get, _) = command.kind {
            selected = get(engine)
        }

        let clicked = label.withCString { labelPointer in
            shortcut.withCString { shortcutPointer in
                igMenuItem_Bool(
                    labelPointer,
                    shortcut.isEmpty ? nil : shortcutPointer,
                    selected,
                    enabled
                )
            }
        }
        ImGuiText.tooltip(command.help)
        if clicked {
            perform(command, engine: engine, host: host)
        }
    }

    static func perform(_ command: Command, engine: CollimationEngine, host: any UIHost) {
        switch command.kind {
        case .action:
            command.perform(engine, host)
        case .toggle(let get, let set):
            set(engine, !get(engine))
        }
    }
}
