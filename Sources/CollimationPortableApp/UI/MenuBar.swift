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

    static func draw(engine: CollimationEngine, host: any UIHost) {
        guard igBeginMainMenuBar() else { return }
        height = Double(igGetWindowHeight())

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
