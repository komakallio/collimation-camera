import Foundation

/// A keyboard shortcut, described without naming a platform.
///
/// `primary` is Command on macOS and Ctrl elsewhere; `option` is Option on
/// macOS and Alt elsewhere. Each app maps these to its own key handling.
public struct Shortcut: Equatable, Hashable, Sendable {
    public enum Key: Equatable, Hashable, Sendable {
        case character(Character)
        case `return`
    }

    public enum Modifier: Equatable, Hashable, Sendable {
        case primary
        case shift
        case option
    }

    public var key: Key
    public var modifiers: Set<Modifier>

    public init(key: Key, modifiers: Set<Modifier>) {
        self.key = key
        self.modifiers = modifiers
    }

    public static func primary(_ character: Character) -> Shortcut {
        Shortcut(key: .character(character), modifiers: [.primary])
    }

    public static func primaryShift(_ character: Character) -> Shortcut {
        Shortcut(key: .character(character), modifiers: [.primary, .shift])
    }

    public static func option(_ character: Character) -> Shortcut {
        Shortcut(key: .character(character), modifiers: [.option])
    }

    public static let `return` = Shortcut(key: .return, modifiers: [])

    /// Display form for a tooltip or menu row, in the platform's own idiom.
    public var displayString: String {
        var text = ""
#if os(macOS)
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.primary) { text += "⌘" }
        switch key {
        case .character(let character): text += String(character).uppercased()
        case .return: text += "↩"
        }
#else
        if modifiers.contains(.primary) { text += "Ctrl+" }
        if modifiers.contains(.shift) { text += "Shift+" }
        if modifiers.contains(.option) { text += "Alt+" }
        switch key {
        case .character(let character): text += String(character).uppercased()
        case .return: text += "Enter"
        }
#endif
        return text
    }
}
