import CImGui
import CollimationCore
import CollimationUI
import Foundation

/// The three bundled faces.
///
/// Dear ImGui's embedded ProggyClean covers only U+0000–U+00FF and U+20AC, so
/// the characters the shared strings use — "—", "…", "″", "·", "×", "°", and
/// the "⌘"/"⌥" menu glyphs — would render as "?". DejaVu carries all of them
/// and has tabular digits by default, which the metric rows need because ImGui
/// cannot turn on OpenType features.
enum Fonts {
    nonisolated(unsafe) static var proportional: UnsafeMutablePointer<ImFont>?
    nonisolated(unsafe) static var mono: UnsafeMutablePointer<ImFont>?
    nonisolated(unsafe) static var monoBold: UnsafeMutablePointer<ImFont>?

    /// Body size, matching the macOS app's 13 pt.
    static let baseSize: Float = 13
    static let captionSize: Float = 10
    static let hudSize: Float = 8

    static let files = [
        "DejaVuSans.ttf",
        "DejaVuSansMono.ttf",
        "DejaVuSansMono-Bold.ttf",
    ]

    /// Loads the faces. Call after `igCreateContext` and before
    /// `ImGui_ImplSDL3_InitForSDLGPU`. The first font loaded becomes ImGui's
    /// default, so the proportional face goes first.
    ///
    /// Returns false when a file is missing; the caller decides whether that is
    /// fatal. Size 0 asks the 1.92 dynamic atlas to rasterize on demand.
    @discardableResult
    static func load(io: UnsafeMutablePointer<ImGuiIO>) -> Bool {
        var loadedAll = true
        var loaded: [UnsafeMutablePointer<ImFont>?] = []
        for file in files {
            guard let url = AppPaths.font(file) else {
                Log.info("font missing: \(file) (searched \(AppPaths.resourceRoots.map(\.path).joined(separator: ", ")))")
                loaded.append(nil)
                loadedAll = false
                continue
            }
            let font = url.path.withCString { path in
                ImFontAtlas_AddFontFromFileTTF(io.pointee.Fonts, path, 0, nil, nil)
            }
            if font == nil {
                Log.info("font failed to load: \(url.path)")
                loadedAll = false
            } else {
                Log.info("font: \(url.path)")
            }
            loaded.append(font)
        }
        proportional = loaded.count > 0 ? loaded[0] : nil
        mono = loaded.count > 1 ? loaded[1] : nil
        monoBold = loaded.count > 2 ? loaded[2] : nil
        return loadedAll
    }

    /// Logs any missing glyph rather than failing: a wrong glyph is cosmetic.
    /// The list is `UIGlyphs`, the same one the `ui glyph coverage` test reads
    /// the font files against, so a font swap that loses a character is caught
    /// in CI as well as at startup.
    static func verifyGlyphs() {
        guard let proportional else { return }
        for glyph in UIGlyphs.all {
            if !ImFont_IsGlyphInFont(proportional, ImWchar(glyph.scalar.value)) {
                Log.info("glyph missing from the proportional face: \(glyph.name)")
            }
        }
        guard let mono else { return }
        for glyph in UIGlyphs.metrics {
            if !ImFont_IsGlyphInFont(mono, ImWchar(glyph.scalar.value)) {
                Log.info("glyph missing from the monospaced face: \(glyph.name)")
            }
        }
    }

    static func font(monospaced: Bool, weight: HUDWeight) -> UnsafeMutablePointer<ImFont>? {
        guard monospaced else { return proportional }
        switch weight {
        case .bold: return monoBold ?? mono
        default: return mono
        }
    }
}
