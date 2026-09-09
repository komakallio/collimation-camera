import CImGui
import CSDL3
import CollimationCore
import CollimationUI
import Foundation

/// SDL events and ImGui shortcuts, translated into engine calls.
@MainActor
enum Input {
    /// Zoom step per wheel event, by the sign of the delta. One factor per
    /// event, not per accumulated tick — the same rule `LiveMTKView.onScroll`
    /// follows, and a trackpad produces many small events on both platforms.
    static let zoomIn = 1.08
    static let zoomOut = 0.92

    static func handle(
        event: SDL_Event,
        engine: CollimationEngine,
        liveRect: (origin: SIMD2<Double>, size: SIMD2<Double>),
        pointScale: Double,
        shouldQuit: inout Bool
    ) {
        // SDL event constants import with an Int32 raw value while event.type is
        // UInt32, so these are compared rather than switched.
        let type = event.type
        if type == UInt32(SDL_EVENT_QUIT.rawValue) || type == UInt32(SDL_EVENT_WINDOW_CLOSE_REQUESTED.rawValue) {
            shouldQuit = true
            return
        }

        if type == UInt32(SDL_EVENT_MOUSE_WHEEL.rawValue) {
            // ImGui owns the wheel while the pointer is over a window.
            guard let io = igGetIO_Nil(), !io.pointee.WantCaptureMouse else { return }
            guard event.wheel.y != 0 else { return }
            let factor = event.wheel.y > 0 ? zoomIn : zoomOut
            engine.zoom = engine.clampedZoom(engine.zoom * factor)
            engine.updateStabilization()
            return
        }

#if os(macOS)
        // Trackpad pinch, macOS and Wayland only (SDL 3.4+). Windows has no
        // pinch event; precision touchpads send Ctrl + wheel instead.
        if type == UInt32(SDL_EVENT_PINCH_UPDATE.rawValue) {
            guard let io = igGetIO_Nil(), !io.pointee.WantCaptureMouse else { return }
            let scale = Double(event.pinch.scale)
            guard scale > 0 else { return }
            engine.zoom = engine.clampedZoom(engine.zoom * scale)
            engine.updateStabilization()
            return
        }
#endif
    }

    /// Global shortcuts from the catalog. ImGui's routing skips these while a
    /// text field has focus, and it maps Ctrl to Cmd on macOS by itself.
    static func handleShortcuts(engine: CollimationEngine, host: any UIHost) {
        // A modal owns the keyboard: Return must not reach the connect command
        // while the error dialog is asking about the last one.
        let anyPopup = Int32(ImGuiPopupFlags_AnyPopupId.rawValue | ImGuiPopupFlags_AnyPopupLevel.rawValue)
        guard !igIsPopupOpen_Str(nil, anyPopup) else { return }

        for command in CommandCatalog.all + CommandCatalog.filterCommands(engine) {
            guard command.isEnabled(engine) else { continue }
            for shortcut in command.shortcuts {
                guard let chord = chord(for: shortcut) else { continue }
                if igShortcut_Nil(chord, Int32(ImGuiInputFlags_RouteGlobal.rawValue)) {
                    MenuBar.perform(command, engine: engine, host: host)
                }
            }
        }
    }

    /// `Shortcut` to an ImGui key chord. `.primary` is `ImGuiMod_Ctrl`, which
    /// ImGui itself renders and matches as Cmd on macOS.
    static func chord(for shortcut: Shortcut) -> ImGuiKeyChord? {
        var chord: ImGuiKeyChord = 0
        if shortcut.modifiers.contains(.primary) { chord |= Int32(ImGuiMod_Ctrl.rawValue) }
        if shortcut.modifiers.contains(.shift) { chord |= Int32(ImGuiMod_Shift.rawValue) }
        if shortcut.modifiers.contains(.option) { chord |= Int32(ImGuiMod_Alt.rawValue) }

        switch shortcut.key {
        case .return:
            return chord | Int32(ImGuiKey_Enter.rawValue)
        case .character(let character):
            guard let key = key(for: character) else { return nil }
            return chord | key
        }
    }

    private static func key(for character: Character) -> Int32? {
        let lower = Character(character.lowercased())
        if let ascii = lower.asciiValue {
            if ascii >= UInt8(ascii: "a"), ascii <= UInt8(ascii: "z") {
                return Int32(ImGuiKey_A.rawValue) + Int32(ascii - UInt8(ascii: "a"))
            }
            if ascii >= UInt8(ascii: "1"), ascii <= UInt8(ascii: "9") {
                return Int32(ImGuiKey_1.rawValue) + Int32(ascii - UInt8(ascii: "1"))
            }
            if ascii == UInt8(ascii: "0") {
                return Int32(ImGuiKey_0.rawValue)
            }
        }
        return nil
    }
}
