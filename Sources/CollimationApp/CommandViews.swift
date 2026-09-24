import AppKit
import CollimationCore
import CollimationUI
import SwiftUI
import UniformTypeIdentifiers

/// Renders a `Command` as a menu item or a sidebar control.
///
/// Every label, tooltip, shortcut, and enablement rule comes from the catalog,
/// so this is the only place the macOS app turns a command into a control
/// (§12.1 item 3).
struct CommandButton: View {
    let command: Command
    let engine: CollimationEngine
    let host: any UIHost
    /// Sidebar buttons use the short label; menu items use the full one.
    var useShortTitle = false
    var appliesShortcut = true

    var body: some View {
        Group {
            switch command.kind {
            case .action:
                Button(label) { command.perform(engine, host) }
            case .toggle(let get, let set):
                if useShortTitle {
                    // The sidebar renders a toggle as a button that flips it,
                    // the way the pre-port sidebar did for the overlay.
                    Button(label) { set(engine, !get(engine)) }
                } else {
                    Toggle(label, isOn: Binding(
                        get: { get(engine) },
                        set: { set(engine, $0) }
                    ))
                }
            }
        }
        .disabled(!command.isEnabled(engine))
        .modifier(ShortcutModifier(shortcuts: appliesShortcut ? command.shortcuts : []))
        .modifier(HelpModifier(text: command.help))
    }

    private var label: String {
        useShortTitle ? command.sidebarTitle(engine) : command.title(engine)
    }
}

/// A sidebar toggle that keeps the switch affordance rather than a button.
struct CommandToggle: View {
    let command: Command
    let engine: CollimationEngine
    var appliesShortcut = false

    var body: some View {
        Group {
            if case .toggle(let get, let set) = command.kind {
                Toggle(command.sidebarTitle(engine), isOn: Binding(
                    get: { get(engine) },
                    set: { set(engine, $0) }
                ))
            }
        }
        .disabled(!command.isEnabled(engine))
        .modifier(ShortcutModifier(shortcuts: appliesShortcut ? command.shortcuts : []))
        .modifier(HelpModifier(text: command.help))
    }
}

/// Applies at most one keyboard shortcut. SwiftUI takes a single
/// `KeyboardShortcut` per view, so a command with two bindings (Connect has
/// ⌘K and Return) gets the first here and the second where it is rendered.
private struct ShortcutModifier: ViewModifier {
    let shortcuts: [Shortcut]

    func body(content: Content) -> some View {
        if let shortcut = shortcuts.first, let equivalent = Self.keyEquivalent(shortcut.key) {
            content.keyboardShortcut(equivalent, modifiers: Self.modifiers(shortcut.modifiers))
        } else {
            content
        }
    }

    static func keyEquivalent(_ key: Shortcut.Key) -> KeyEquivalent? {
        switch key {
        case .character(let character): return KeyEquivalent(character)
        case .return: return .return
        }
    }

    static func modifiers(_ modifiers: Set<Shortcut.Modifier>) -> EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.primary) { result.insert(.command) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.option) { result.insert(.option) }
        return result
    }
}

private struct HelpModifier: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text {
            content.help(text)
        } else {
            content
        }
    }
}

/// The macOS `UIHost`: an `NSSavePanel` per save command.
///
/// `dialogOpen` is what stops a repeated ⌘S from stacking two panels.
@MainActor
final class MacUIHost: UIHost {
    private var dialogOpen = false

    func presentSaveDialog(
        title: String,
        message: String,
        suggestedName: String,
        directory: URL?,
        completion: @escaping @MainActor (URL?) -> Void
    ) {
        guard !dialogOpen else { return }
        dialogOpen = true
        defer { dialogOpen = false }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.tiff]
        panel.nameFieldStringValue = suggestedName
        panel.title = title
        panel.message = message
        panel.directoryURL = directory
        guard panel.runModal() == .OK, let url = panel.url else {
            completion(nil)
            return
        }
        completion(url)
    }
}
