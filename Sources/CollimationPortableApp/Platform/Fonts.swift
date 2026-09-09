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

    /// Codepoints the UI depends on. Checked after loading so a bad font file
    /// is a log line rather than a screen full of "?".
    static let requiredCodepoints: [(String, UInt32)] = [
        ("° degree", 0x00B0),
        ("· middot", 0x00B7),
        ("× times", 0x00D7),
        ("— em dash", 0x2014),
        ("… ellipsis", 0x2026),
        ("″ double prime", 0x2033),
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
    static func verifyGlyphs() {
        guard let proportional else { return }
        for (name, codepoint) in requiredCodepoints {
            if !ImFont_IsGlyphInFont(proportional, ImWchar(codepoint)) {
                Log.info("glyph missing from the proportional face: \(name)")
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
