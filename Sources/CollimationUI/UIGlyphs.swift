import Foundation

/// The non-ASCII characters the shared UI is allowed to put on screen.
///
/// Dear ImGui's built-in face covers only Latin-1, so the portable app bundles
/// DejaVu and checks these at startup; the `ui glyph coverage` test checks the
/// same list against the font files, and checks that nothing outside it turns
/// up in `CollimationUI`. §9.8: no UI string may render as a fallback "?".
public enum UIGlyphs {
    public struct Glyph: Sendable {
        public let name: String
        public let scalar: Unicode.Scalar

        public init(_ name: String, _ value: UInt32) {
            self.name = name
            self.scalar = Unicode.Scalar(value) ?? " "
        }
    }

    /// Characters that appear in a metric readout, which both apps set in a
    /// monospaced face.
    public static let metrics: [Glyph] = [
        Glyph("degree", 0x00B0),
        Glyph("micro", 0x00B5),
        Glyph("middot", 0x00B7),
        Glyph("times", 0x00D7),
        Glyph("en dash", 0x2013),
        Glyph("em dash", 0x2014),
        Glyph("ellipsis", 0x2026),
        Glyph("double prime", 0x2033),
    ]

    /// Everything else: prose in tooltips and section text, and the menu
    /// shortcut symbols, which `Shortcut.displayString` produces on macOS only
    /// — on Windows it spells out Ctrl, Shift, Alt, and Enter.
    public static let prose: [Glyph] = [
        Glyph("section sign", 0x00A7),
        Glyph("greek small alpha", 0x03B1),
        Glyph("leftwards arrow with hook", 0x21A9),
        Glyph("upwards white arrow", 0x21E7),
        Glyph("place of interest sign", 0x2318),
        Glyph("option key", 0x2325),
    ]

    public static let all: [Glyph] = metrics + prose

    public static func contains(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII || all.contains { $0.scalar == scalar }
    }
}
