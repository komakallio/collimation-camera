import CollimationCore
import CollimationUI
import Foundation

// §9.8: no UI string may render as a fallback "?". The portable app bundles
// DejaVu because Dear ImGui's built-in face stops at Latin-1, so this reads the
// font files and checks that every character the shared UI can emit has a
// glyph. It also catches a character typed into CollimationUI that nobody
// added to UIGlyphs.

/// Minimal TrueType reader: the table directory, then the `cmap` subtable, and
/// nothing else. Formats 4 and 12 are the two Microsoft encodings DejaVu ships.
private struct TrueTypeFont {
    private let bytes: [UInt8]
    private var coverage: Set<UInt32> = []

    init?(path: String) {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        bytes = [UInt8](data)
        guard let cmap = Self.tableOffset(bytes, tag: "cmap") else { return nil }
        guard let subtable = Self.bestSubtable(bytes, cmap: cmap) else { return nil }
        guard let covered = Self.readCoverage(bytes, at: subtable) else { return nil }
        coverage = covered
    }

    func covers(_ scalar: Unicode.Scalar) -> Bool {
        coverage.contains(scalar.value)
    }

    // MARK: - Reading

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> Int? {
        guard offset >= 0, offset + 1 < bytes.count else { return nil }
        return Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> Int? {
        guard offset >= 0, offset + 3 < bytes.count else { return nil }
        return Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
            | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
    }

    private static func tableOffset(_ bytes: [UInt8], tag: String) -> Int? {
        guard let count = u16(bytes, 4) else { return nil }
        let wanted = Array(tag.utf8)
        for index in 0..<count {
            let record = 12 + index * 16
            guard record + 16 <= bytes.count else { return nil }
            if Array(bytes[record..<(record + 4)]) == wanted {
                return u32(bytes, record + 8)
            }
        }
        return nil
    }

    /// (3,10) is UCS-4, (3,1) is BMP. Either is enough here; prefer the wider.
    private static func bestSubtable(_ bytes: [UInt8], cmap: Int) -> Int? {
        guard let count = u16(bytes, cmap + 2) else { return nil }
        var best: (score: Int, offset: Int)?
        for index in 0..<count {
            let record = cmap + 4 + index * 8
            guard let platform = u16(bytes, record),
                  let encoding = u16(bytes, record + 2),
                  let offset = u32(bytes, record + 4) else { return nil }
            let score: Int
            switch (platform, encoding) {
            case (3, 10): score = 3
            case (3, 1): score = 2
            case (0, _): score = 1
            default: score = 0
            }
            if score > 0, score > (best?.score ?? 0) {
                best = (score, cmap + offset)
            }
        }
        return best?.offset
    }

    private static func readCoverage(_ bytes: [UInt8], at offset: Int) -> Set<UInt32>? {
        guard let format = u16(bytes, offset) else { return nil }
        switch format {
        case 4:
            guard let segCountX2 = u16(bytes, offset + 6) else { return nil }
            let segments = segCountX2 / 2
            let endCodes = offset + 14
            let startCodes = endCodes + segCountX2 + 2
            var covered: Set<UInt32> = []
            for segment in 0..<segments {
                guard let end = u16(bytes, endCodes + segment * 2),
                      let start = u16(bytes, startCodes + segment * 2) else { return nil }
                guard start <= end, end != 0xFFFF || start != 0xFFFF else { continue }
                // The mapping itself does not matter: a code point inside a
                // segment has a glyph unless idRangeOffset maps it to 0, which
                // DejaVu does not do for the characters this checks.
                for code in start...end { covered.insert(UInt32(code)) }
            }
            return covered
        case 12:
            guard let groups = u32(bytes, offset + 12) else { return nil }
            var covered: Set<UInt32> = []
            for group in 0..<groups {
                let record = offset + 16 + group * 12
                guard let start = u32(bytes, record), let end = u32(bytes, record + 4) else { return nil }
                guard start <= end, end - start < 0x11_0000 else { continue }
                for code in start...end { covered.insert(UInt32(code)) }
            }
            return covered
        default:
            return nil
        }
    }
}

/// The repository root, from this file's own path.
private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)      // Sources/CoreTests/GlyphCoverageTests.swift
        .deletingLastPathComponent()     // Sources/CoreTests
        .deletingLastPathComponent()     // Sources
        .deletingLastPathComponent()     // repository root
}

/// Every non-ASCII scalar that appears in the shared UI module's sources.
/// Comments count: a character typed there is a character somebody may move
/// into a string, and adding it to `UIGlyphs` costs one line.
private func scalarsInSharedSources() throws -> Set<Unicode.Scalar> {
    let directory = repositoryRoot().appendingPathComponent("Sources/CollimationUI")
    let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        .filter { $0.hasSuffix(".swift") }
    try expectUI(!files.isEmpty, "no sources found under \(directory.path)")

    var scalars: Set<Unicode.Scalar> = []
    for file in files {
        let text = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
        for scalar in text.unicodeScalars where !scalar.isASCII {
            scalars.insert(scalar)
        }
    }
    return scalars
}

/// Strings the shared API produces at run time, which may pull characters in
/// from CollimationCore rather than from CollimationUI's own sources.
@MainActor
private func renderedUIStrings() throws -> [String] {
    let (engine, suite) = try makeTestEngine(suffix: "glyphs")
    defer {
        engine.disconnect()
        engine.shutdown()
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    var strings: [String] = [
        MetricText.placeholder,
        MetricText.serialPortPlaceholder,
        MetricText.roiExplanation,
        HelpText.stackCount,
        HelpText.stackedSave,
        HelpText.roiSection,
        HelpText.arcsinh,
        HelpText.fwhm,
        HelpText.legend,
        HelpText.roiMap,
        HelpText.starProfile,
        HelpText.filterPicker(slotCount: 7),
    ]

    strings.append(contentsOf: [
        MetricText.coma(nil),
        MetricText.direction(nil),
        MetricText.asymmetry(nil),
        MetricText.fwhm(nil, trackingState: .searching),
        MetricText.snr(nil, trackingState: .searching),
        MetricText.exposureLabel(microseconds: 50_000),
        MetricText.exposureLabel(microseconds: 250),
        MetricText.percent(0.5),
        MetricText.gain(120),
        MetricText.midtones(0.25),
        MetricText.arcsinhFactor(10),
        MetricText.zoomPercent(1.5),
        MetricText.zoomAndFPS(zoom: 1, fps: 30),
        MetricText.stackCount(1_000),
        MetricText.serialPortName("/dev/cu.usbserial-1"),
        MetricText.filterWheelPlaceholder(sdkPresent: true),
        MetricText.filterWheelPlaceholder(sdkPresent: false),
    ])

    for command in CommandCatalog.all {
        strings.append(command.title(engine))
        if let help = command.help { strings.append(help) }
        strings.append(contentsOf: command.shortcuts.map(\.displayString))
    }
    for menu in CommandMenu.allCases { strings.append(menu.title) }
    for state in [TrackingState.idle, .tracking, .lost, .searching] {
        strings.append(
            StatusChip.model(
                stackWork: nil,
                mountWork: nil,
                isAutoExposing: false,
                trackingState: state
            ).label
        )
    }
    strings.append(StatusChip.model(engine).label)
    strings.append(contentsOf: LegendScene.rows.map(\.label))

    return strings
}

@MainActor
func testUIGlyphCoverage() throws {
    // Nothing outside the allow list may appear in the shared module.
    for scalar in try scalarsInSharedSources() {
        try expectUI(
            UIGlyphs.contains(scalar),
            "U+\(String(scalar.value, radix: 16, uppercase: true)) is used in CollimationUI but not listed in UIGlyphs"
        )
    }

    // Nor in anything the shared API renders, which can draw on CollimationCore.
    for text in try renderedUIStrings() {
        for scalar in text.unicodeScalars {
            try expectUI(
                UIGlyphs.contains(scalar),
                "U+\(String(scalar.value, radix: 16, uppercase: true)) in \"\(text)\" is not listed in UIGlyphs"
            )
        }
    }

    // And the bundled faces have to have all of them. The mono faces carry the
    // metric characters; the proportional one carries everything.
    let fonts = repositoryRoot().appendingPathComponent("Resources/Fonts")
    guard let proportional = TrueTypeFont(path: fonts.appendingPathComponent("DejaVuSans.ttf").path) else {
        throw UIModelExpectation(description: "could not read DejaVuSans.ttf")
    }
    for glyph in UIGlyphs.all {
        try expectUI(
            proportional.covers(glyph.scalar),
            "DejaVuSans has no glyph for \(glyph.name) (U+\(String(glyph.scalar.value, radix: 16, uppercase: true)))"
        )
    }
    for name in ["DejaVuSansMono.ttf", "DejaVuSansMono-Bold.ttf"] {
        guard let mono = TrueTypeFont(path: fonts.appendingPathComponent(name).path) else {
            throw UIModelExpectation(description: "could not read \(name)")
        }
        for glyph in UIGlyphs.metrics {
            try expectUI(
                mono.covers(glyph.scalar),
                "\(name) has no glyph for \(glyph.name) (U+\(String(glyph.scalar.value, radix: 16, uppercase: true)))"
            )
        }
        // Digits are the reason these faces are here at all.
        for digit in "0123456789".unicodeScalars {
            try expectUI(mono.covers(digit), "\(name) has no glyph for \(digit)")
        }
    }
}
