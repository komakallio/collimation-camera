import CImGui
import CSDL3
import CollimationCore
import CollimationUI
import Foundation

/// What SDL calls when the save dialog closes, on its own thread on Windows.
///
/// A file-scope function on purpose. Written as a closure inside
/// `PortableUIHost` it inherited that class's `@MainActor` isolation, and
/// Swift emits an isolation check at the entry of an isolated closure reached
/// through a C function pointer. On SDL's dialog thread that check is
/// `dispatch_assert_queue` against the main queue, it fails, and libdispatch
/// answers a failed assertion with `ud2`: the process died of
/// STATUS_ILLEGAL_INSTRUCTION before the first line of the body ran, on every
/// single Save TIFF. Nothing was written and nothing was logged, which is what
/// made it look like a hang — the freeze is Windows Error Reporting collecting
/// the crash.
///
/// The SDL log callback next door in `Diagnostics` fires from SDL's threads
/// constantly and has never crashed, because `Diagnostics` is a plain enum and
/// its closure is nonisolated. That is the difference, and it is the reason to
/// keep every C callback out of an isolated type.
private func portableDialogCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ files: UnsafePointer<UnsafePointer<CChar>?>?,
    _ filter: Int32
) {
    _ = userdata
    _ = filter
    // A cancelled dialog gives a list whose first entry is null; an error
    // gives no list at all. Both mean "no file".
    var chosen: URL?
    if let files, let first = files.pointee {
        chosen = URL(fileURLWithPath: String(cString: first))
    }
    Log.info("save dialog: \(chosen.map { "chose \($0.path)" } ?? "cancelled")")
    PortableUIHost.deliverDialogResult(chosen)
}

/// The portable `UIHost`: SDL's native save dialog, plus the error modal.
///
/// SDL runs the callback on a worker thread on Windows and on the main thread
/// on macOS, so the result is parked and consumed by the main loop rather than
/// touching the engine from whatever thread called back. The filter array must
/// outlive the call, hence the static storage.
@MainActor
final class PortableUIHost: UIHost {
    /// SDL parents the dialog to this window, so it cannot appear behind the
    /// app or steal focus from another program.
    private let window: OpaquePointer
    private var dialogOpen = false
    private var pending: ((URL?) -> Void)?

    init(window: OpaquePointer) {
        self.window = window
    }

    /// SDL runs the dialog callback on a worker thread on Windows, so the
    /// result is parked in a nonisolated box and picked up by the main loop.
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: URL??

        func set(_ url: URL?) {
            lock.lock()
            value = .some(url)
            lock.unlock()
        }

        func take() -> URL?? {
            lock.lock()
            defer { lock.unlock() }
            let current = value
            value = nil
            return current
        }
    }

    private let box = ResultBox()

    /// SDL keeps the filter strings for as long as the dialog is open, so they
    /// are leaked deliberately. `strdup` is spelled `_strdup` on Windows, so
    /// this copies the bytes itself rather than picking a name per platform.
    private static func staticCString(_ text: String) -> UnsafePointer<CChar> {
        let bytes = Array(text.utf8CString)
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
        buffer.update(from: bytes, count: bytes.count)
        return UnsafePointer(buffer)
    }

    private static let filters: [SDL_DialogFileFilter] = [
        SDL_DialogFileFilter(name: staticCString("TIFF image"), pattern: staticCString("tif;tiff")),
        SDL_DialogFileFilter(name: staticCString("All files"), pattern: staticCString("*")),
    ]

    nonisolated(unsafe) private static var active: PortableUIHost?

    func presentSaveDialog(
        title: String,
        message: String,
        suggestedName: String,
        directory: URL?,
        completion: @escaping @MainActor (URL?) -> Void
    ) {
        // A second command while a dialog is open is ignored, so a repeated
        // shortcut cannot stack two dialogs.
        guard !dialogOpen else { return }
        dialogOpen = true
        pending = completion
        Self.active = self
        Log.info("save dialog opened: \(title) — \(message)")

        let start = directory?.appendingPathComponent(suggestedName).path ?? suggestedName
        start.withCString { location in
            Self.filters.withUnsafeBufferPointer { buffer in
                SDL_ShowSaveFileDialog(
                    portableDialogCallback,
                    nil,
                    window,
                    buffer.baseAddress,
                    Int32(buffer.count),
                    location
                )
            }
        }
    }

    /// Entry point for the C callback, which has no `self` to work with.
    nonisolated static func deliverDialogResult(_ url: URL?) {
        active?.deliver(url)
    }

    /// Called from SDL's thread on Windows; only parks the value.
    nonisolated private func deliver(_ url: URL?) {
        box.set(url)
    }

    /// Drained once per frame by the main loop, on the main actor.
    func pumpDialogResult() {
        guard let value = box.take() else { return }
        let completion = pending
        pending = nil
        dialogOpen = false
        completion?(value)
    }
}

/// The error alert, the counterpart of the SwiftUI app's `.alert("Error", …)`.
///
/// `engine.errorMessage` is the single source: setting it opens the modal, and
/// OK clears it. Drawn last in the frame so it sits above the sidebar and the
/// HUD.
@MainActor
enum ErrorDialog {
    private static let title = "Error"

    static func draw(engine: CollimationEngine) {
        // ImGui opens a popup by id, and the id has to be pushed in the same
        // frame the popup is begun, so the open call happens here rather than
        // where the error is set.
        let hasError = engine.errorMessage != nil
        if hasError, !igIsPopupOpen_Str(title, 0) {
            igOpenPopup_Str(title, 0)
        }

        // Keyboard focus, and only while this modal is up.
        //
        // ImGui gives a widget keyboard focus only when NavEnableKeyboard is
        // set, and it is off by default, so OK could never be reached from the
        // keyboard: no focus ring, and Space did nothing. Leaving it on for the
        // whole app is not the answer — Return is the Connect shortcut, and
        // with navigation on it would go to whatever widget held focus instead.
        // Scoping it to the modal costs nothing, because `handleShortcuts`
        // already refuses to run any shortcut while a popup is open, so the two
        // never apply at the same moment.
        if let io = igGetIO_Nil() {
            let nav = Int32(ImGuiConfigFlags_NavEnableKeyboard.rawValue)
            if hasError {
                io.pointee.ConfigFlags |= nav
            } else {
                io.pointee.ConfigFlags &= ~nav
            }
        }

        let viewport = igGetMainViewport()
        let center = viewport.map {
            ImVec2(
                x: $0.pointee.Pos.x + $0.pointee.Size.x * 0.5,
                y: $0.pointee.Pos.y + $0.pointee.Size.y * 0.5
            )
        } ?? ImVec2(x: 0, y: 0)
        igSetNextWindowPos(center, Int32(ImGuiCond_Appearing.rawValue), ImVec2(x: 0.5, y: 0.5))

        let flags = Int32(ImGuiWindowFlags_AlwaysAutoResize.rawValue)
        guard title.withCString({ igBeginPopupModal($0, nil, flags) }) else { return }
        defer { igEndPopup() }

        // The engine clears the message itself on the next successful command,
        // and igCloseCurrentPopup is only valid from inside the popup.
        guard hasError else {
            igCloseCurrentPopup()
            return
        }

        igPushTextWrapPos(igGetFontSize() * 24)
        ImGuiText.plain(engine.errorMessage ?? "")
        igPopTextWrapPos()
        igSpacing()

        let appearing = igIsWindowAppearing()
        let dismissed = "OK".withCString { igButton($0, ImVec2(x: 120 * Float(UIScale.pointScale), y: 0)) }
        // Focus lands on OK as the dialog opens, so it is obvious what Enter
        // and Space will do and there is a focus ring to say so.
        if appearing { igSetItemDefaultFocus() }
        // Explicit keys as well as the focused button, because the button only
        // answers the keyboard while navigation is on, and Escape has no
        // button to be focused on. Keypad Enter is a separate key to ImGui, and
        // somebody at a telescope is as likely to hit that one.
        //
        // Not on the frame the popup appears: the key press that triggered the
        // failing command would otherwise dismiss the report of it.
        let keys: [ImGuiKey] = [ImGuiKey_Escape, ImGuiKey_Enter, ImGuiKey_KeypadEnter, ImGuiKey_Space]
        let confirmed = !appearing && keys.contains { igIsKeyPressed_Bool($0, false) }
        if dismissed || confirmed {
            engine.errorMessage = nil
            igCloseCurrentPopup()
        }
    }
}
