import CollimationCore
import Foundation

/// The menus both apps present. A command with no menu is sidebar-only.
public enum CommandMenu: String, Equatable, Sendable, CaseIterable {
    case camera
    case mount
    case filterWheel
    case view

    public var title: String {
        switch self {
        case .camera: return "Camera"
        case .mount: return "Mount"
        case .filterWheel: return "Filter Wheel"
        case .view: return "View"
        }
    }
}

/// Platform services a command may need. Each app supplies one.
@MainActor
public protocol UIHost: AnyObject {
    /// Presents a save dialog. Must ignore the call while one is already open,
    /// so a repeated shortcut cannot stack two dialogs. `completion` runs on
    /// the main actor with nil when the user cancels.
    func presentSaveDialog(
        title: String,
        message: String,
        suggestedName: String,
        directory: URL?,
        completion: @escaping @MainActor (URL?) -> Void
    )
}

/// One user-facing action, declared once and rendered by every surface.
///
/// A view never spells a label, shortcut, tooltip, or enablement rule of its
/// own; it looks the command up by id and renders what it finds. That is what
/// keeps the two UIs from drifting (§12.1).
public struct Command: Identifiable, Sendable {
    public enum Kind: Sendable {
        case action
        case toggle(
            get: @MainActor @Sendable (CollimationEngine) -> Bool,
            set: @MainActor @Sendable (CollimationEngine, Bool) -> Void
        )
    }

    public var id: String
    /// nil means the command appears only in a sidebar.
    public var menu: CommandMenu?
    public var kind: Kind
    public var title: @MainActor @Sendable (CollimationEngine) -> String
    /// Sidebar label when it differs from the menu title. nil means use `title`.
    public var shortTitle: (@MainActor @Sendable (CollimationEngine) -> String)?
    public var help: String?
    /// Connect has both ⌘K and Return, so this is a list.
    public var shortcuts: [Shortcut]
    public var isEnabled: @MainActor @Sendable (CollimationEngine) -> Bool
    public var perform: @MainActor @Sendable (CollimationEngine, any UIHost) -> Void

    public init(
        id: String,
        menu: CommandMenu?,
        kind: Kind = .action,
        title: @escaping @MainActor @Sendable (CollimationEngine) -> String,
        shortTitle: (@MainActor @Sendable (CollimationEngine) -> String)? = nil,
        help: String? = nil,
        shortcuts: [Shortcut] = [],
        isEnabled: @escaping @MainActor @Sendable (CollimationEngine) -> Bool = { _ in true },
        perform: @escaping @MainActor @Sendable (CollimationEngine, any UIHost) -> Void = { _, _ in }
    ) {
        self.id = id
        self.menu = menu
        self.kind = kind
        self.title = title
        self.shortTitle = shortTitle
        self.help = help
        self.shortcuts = shortcuts
        self.isEnabled = isEnabled
        self.perform = perform
    }

    /// Convenience for a fixed label.
    public init(
        id: String,
        menu: CommandMenu?,
        kind: Kind = .action,
        title: String,
        shortTitle: String? = nil,
        help: String? = nil,
        shortcuts: [Shortcut] = [],
        isEnabled: @escaping @MainActor @Sendable (CollimationEngine) -> Bool = { _ in true },
        perform: @escaping @MainActor @Sendable (CollimationEngine, any UIHost) -> Void = { _, _ in }
    ) {
        let fixedTitle: @MainActor @Sendable (CollimationEngine) -> String = { _ in title }
        var fixedShortTitle: (@MainActor @Sendable (CollimationEngine) -> String)?
        if let shortTitle {
            fixedShortTitle = { _ in shortTitle }
        }
        self.init(
            id: id,
            menu: menu,
            kind: kind,
            title: fixedTitle,
            shortTitle: fixedShortTitle,
            help: help,
            shortcuts: shortcuts,
            isEnabled: isEnabled,
            perform: perform
        )
    }

    /// Label a sidebar shows: `shortTitle` when present, otherwise `title`.
    @MainActor
    public func sidebarTitle(_ engine: CollimationEngine) -> String {
        (shortTitle ?? title)(engine)
    }

    public var isToggle: Bool {
        if case .toggle = kind { return true }
        return false
    }
}
