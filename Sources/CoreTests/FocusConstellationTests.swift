import CollimationCore
import CollimationUI
import Foundation

func testFocusConstellationPlan() throws {
    let plan = try FocusConstellationPlan(bestFocus: 30000, maximum: 100000, takeUp: 4000)
    try expectUI(plan.positions == Array(stride(from: 26000, through: 34000, by: 250)), "33 inclusive absolute positions")
    try expectUI(plan.positions[plan.settings.centerIndex] == plan.bestFocus, "middle layer is centre best focus")
    try expectUI(plan.moves(for: 0) == [22000, 26000], "take up backlash below the first exposure")
    for i in 1..<33 {
        try expectUI(plan.moves(for: i) == [plan.positions[i]] && plan.positions[i] - plan.positions[i - 1] == 250,
                     "remaining exposures approach in the same direction without extra reversal")
    }
    _ = try FocusConstellationPlan(bestFocus: 8000, maximum: 12000, takeUp: 4000)
    for (best, maximum, takeUp) in [(7999, 100000, 4000), (96001, 100000, 4000), (30000, 33999, 4000),
                                   (4000, 100000, 1), (30000, 100000, 0), (Int.max, Int.max, 4000)] {
        do {
            _ = try FocusConstellationPlan(bestFocus: best, maximum: maximum, takeUp: takeUp)
            throw UIModelExpectation(description: "unsafe sweep range accepted")
        } catch is CameraError {}
    }
    let custom = try FocusConstellationSettings(range: 2000, step: 500)
    let shorter = try FocusConstellationPlan(bestFocus: 6000, maximum: 8000, takeUp: 4000, settings: custom)
    try expectUI(shorter.positions == Array(stride(from: 4000, through: 8000, by: 500))
        && shorter.positions[custom.centerIndex] == 6000 && shorter.moves(for: 0) == [0, 4000],
        "custom range and step retain both endpoints, best focus and backlash at travel boundaries")
    let nearMaximum = try FocusConstellationPlan(bestFocus: Int.max - 2000, maximum: Int.max,
        takeUp: 4000, settings: custom)
    try expectUI(nearMaximum.positions.last == Int.max, "large safe positions do not overflow")
    for (range, step) in [(0, 250), (-1000, 250), (4000, 0), (4000, -250), (4000, 300),
                          (250, 500), (Int.max, 1), (7250, 250)] {
        do {
            _ = try FocusConstellationSettings(range: range, step: step)
            throw UIModelExpectation(description: "invalid sweep settings accepted")
        } catch is CameraError {}
    }
    try expectUI(try FocusConstellationSettings(range: 7000, step: 250).count == 57,
                 "largest supported recording has 57 focus positions")
}

private func focusMetadata(_ layout: ConstellationLayout,
                           settings: FocusConstellationSettings = try! FocusConstellationSettings()) throws -> FocusConstellationMetadata {
    FocusConstellationMetadata(plan: try FocusConstellationPlan(bestFocus: 30000, maximum: 100000, takeUp: 4000, settings: settings),
        maximum: 100000, layout: layout, sensorWidth: 3856, sensorHeight: 2180, frameCount: 100,
        exposureMicroseconds: 10000, gain: 120)
}

private func focusFixtureImages(count: Int = 33) -> [StackedImage] {
    (0..<count).map { index in
        let radius = 2 + Double(abs(index - count / 2)) * 2
        var pixels = [Float](repeating: 200.25, count: 256 * 256)
        for y in 80..<176 { for x in 80..<176 {
            let r = hypot(Double(x) - 127.5, Double(y) - 127.5)
            pixels[y * 256 + x] += Float(12000 * exp(-pow(r - radius, 2) / 8))
        } }
        return StackedImage(width: 256, height: 256, pixels: pixels, roi: ROI(x: 0, y: 0, width: 256, height: 256))
    }
}

private func writeFocusFixture(to url: URL, layout: ConstellationLayout,
                               settings: FocusConstellationSettings = try! FocusConstellationSettings()) throws {
    let metadata = try focusMetadata(layout, settings: settings)
    let writer = try FocusConstellationWriter(to: url, metadata: metadata)
    let images = focusFixtureImages(count: settings.count)
    for star in metadata.targets.indices {
        for index in metadata.positions.indices {
            var image = images[index]
            image.pixels[0] = Float(star * 100 + index) + 0.25
            try writer.append(image)
        }
    }
    try writer.finish()
}

func testFocusConstellationTIFF() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("focus-tiff-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for layout in ConstellationLayout.allCases {
        let settings = try FocusConstellationSettings(range: layout == .circular ? 4000 : 5000, step: 250)
        let url = directory.appendingPathComponent("\(layout.rawValue).tif")
        let oldFile = Data("previous completed recording".utf8)
        try oldFile.write(to: url)
        // A partial sweep must neither publish a recording nor destroy the previous file.
        do {
            let writer = try FocusConstellationWriter(to: url, metadata: focusMetadata(layout))
            try writer.append(focusFixtureImages()[0])
            do { try writer.finish(); throw UIModelExpectation(description: "partial sweep committed") }
            catch is CameraError {}
            try expectUI(try Data(contentsOf: url) == oldFile, "partial recording preserves destination")
        }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        try expectUI(!remaining.contains(where: { $0.hasPrefix(".focus-") }),
                     "cancelled writer removes its temporary file")
        try writeFocusFixture(to: url, layout: layout, settings: settings)
        guard let recording = try FocusConstellationRecording.openIfSupported(from: url) else {
            throw UIModelExpectation(description: "recording not recognised")
        }
        try expectUI(recording.metadata == focusMetadata(layout, settings: settings), "complete metadata round trip")
        for index in 0..<settings.count {
            let result = try recording.loadLayer(index: index)
            try expectUI(result.layout == layout && result.focusIndex == index && result.focusRecording?.id == recording.id,
                         "layer keeps recording identity and focus coordinate")
            for (star, target) in recording.metadata.targets.enumerated() {
                let tile = result.tiles.first { $0.row == target.row && $0.column == target.column }!
                try expectUI(tile.image.pixels[0] == Float(star * 100 + index) + 0.25, "star-major, focus-minor ordering retains fractional ADU")
            }
        }
        let reopened = try ConstellationResult.load(from: url)
        try expectUI(reopened.focusIndex == settings.centerIndex && reopened.tiles.count == layout.positionCount, "reopening selects best-focus layer")
        try expectUI(MetricText.constellationFocus(reopened) == "30000 (+0 steps)", "absolute and relative focus label")
        try expectUI(MetricText.constellationFocus(try recording.loadLayer(index: 0)) == "\(30000 - settings.range) (-\(settings.range) steps)", "negative focus label")
        if let fixtureDirectory = ProcessInfo.processInfo.environment["COLLIMATION_FOCUS_CONSTELLATION_FIXTURE_DIR"] {
            let targetDirectory = URL(fileURLWithPath: fixtureDirectory)
            try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
            let target = targetDirectory.appendingPathComponent("\(layout.rawValue)-focus.tif")
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.copyItem(at: url, to: target)
        }
        // Validate broken page chains and incomplete files without reading all pixel data into memory.
        let bad = directory.appendingPathComponent("bad.tif")
        func rejected(_ edit: (FileHandle, UInt64) throws -> Void) throws {
            try FileManager.default.copyItem(at: url, to: bad)
            defer { try? FileManager.default.removeItem(at: bad) }
            let file = try FileHandle(forUpdating: bad)
            let size = try file.seekToEnd()
            try edit(file, size); try file.close()
            do {
                _ = try ConstellationResult.load(from: bad)
                _ = try FocusConstellationRecording.openIfSupported(from: bad)?.loadLayer(index: 0)
            }
            catch { return }
            throw UIModelExpectation(description: "malformed focus TIFF accepted")
        }
        try rejected { file, size in try file.truncate(atOffset: size - 100) }
        let firstLink: UInt64 = 262294 // header + embedded header + pixels + directory entries
        try rejected { file, _ in
            // First directory has 11 entries. Terminating here drops every other crop.
            try file.seek(toOffset: firstLink)
            try file.write(contentsOf: Data(repeating: 0, count: 4))
        }
        try rejected { file, _ in
            try file.seek(toOffset: 4)
            let first = try file.read(upToCount: 4)!
            try file.seek(toOffset: firstLink)
            try file.write(contentsOf: first) // cycle
        }
        try rejected { file, _ in
            try file.seek(toOffset: firstLink)
            let link = [UInt8](try file.read(upToCount: 4)!)
            let secondIFD = link.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * $1.offset) }
            // Point the second strip four bytes into the first: distinct offsets still overlap.
            try file.seek(toOffset: secondIFD + 70)
            try file.write(contentsOf: Data([20, 0, 0, 0]))
        }
        try rejected { file, _ in
            try file.seek(toOffset: 16)
            try file.write(contentsOf: Data([0, 0, 192, 127])) // NaN in centre-star first layer
        }
    }
}

@MainActor
func testFocusConstellationViewer() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("focus-viewer-\(UUID()).tif")
    try writeFocusFixture(to: url, layout: .circular)
    defer { try? FileManager.default.removeItem(at: url) }
    let (engine, suite) = try makeTestEngine(suffix: "focus-viewer")
    defer { engine.shutdown(); UserDefaults.standard.removePersistentDomain(forName: suite) }
    engine.openConstellation(from: url)
    func waitForLoad() async throws {
        let deadline = Date().addingTimeInterval(10)
        while engine.isLoadingConstellation || engine.isLoadingConstellationFocus {
            guard Date() < deadline else { throw UIModelExpectation(description: "focus layer load timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    try await waitForLoad()
    try expectUI(engine.constellationFocusIndex == 16 && engine.constellationResult?.focusIndex == 16, "initial slider at centre optimum")
    let centre = engine.constellationResult!
    engine.constellationZoom = 4
    engine.constellationStretch.black = 0.0123
    let stretch = engine.constellationStretch
    engine.selectConstellationFocus(0)
    engine.selectConstellationFocus(32)
    engine.selectConstellationFocus(5)
    try await waitForLoad()
    try expectUI(engine.constellationResult?.focusIndex == 5 && engine.constellationFocusIndex == 5, "rapid slider changes publish only latest layer")
    try expectUI(engine.constellationZoom == 4 && engine.constellationStretch == stretch, "layer selection preserves zoom and stretch")
    try expectUI(engine.constellationRenderSlot.peek().result?.focusIndex == 5, "render slot follows focus selection")
    engine.selectConstellationFocus(7)
    engine.selectConstellationFocus(16)
    try expectUI(!engine.isLoadingConstellationFocus && engine.constellationResult?.id == centre.id,
                 "cached centre selection immediately cancels a pending load")
    try await Task.sleep(for: .milliseconds(30))
    try expectUI(engine.constellationResult?.id == centre.id, "cancelled request cannot replace cached selection")
    engine.selectConstellationFocus(-10)
    try await waitForLoad()
    try expectUI(engine.constellationFocusIndex == 0, "slider clamps below range")
    let firstLayer = engine.constellationResult!
    engine.selectConstellationFocus(999)
    try await waitForLoad()
    try expectUI(engine.constellationFocusIndex == 32, "slider clamps above range")
    engine.selectConstellationFocus(0)
    try expectUI(!engine.isLoadingConstellationFocus && engine.constellationResult?.id == firstLayer.id,
                 "revisited layer reuses decoded pixels, star centres and histogram")
    for index in 1...9 {
        engine.selectConstellationFocus(index)
        try await waitForLoad()
    }
    engine.selectConstellationFocus(0)
    try await waitForLoad()
    try expectUI(engine.constellationResult?.id != firstLayer.id, "cache evicts least recently viewed layer after eight entries")
    let replacement = try ConstellationResult.load(from: url)
    engine.selectConstellationFocus(10)
    engine.displayConstellation(replacement)
    try await Task.sleep(for: .milliseconds(30))
    try expectUI(engine.constellationResult?.id == replacement.id, "new recording cannot be replaced by old pending focus load")
    engine.selectConstellationFocus(0)
    try await waitForLoad()
    try expectUI(engine.constellationResult?.focusRecording?.id == replacement.focusRecording?.id
        && engine.constellationResult?.id != firstLayer.id, "new recording clears previous layer cache")
    engine.selectConstellationFocus(32)
    try await waitForLoad()
    let previous = engine.constellationResult!.id
    try FileManager.default.removeItem(at: url)
    engine.selectConstellationFocus(20)
    try await waitForLoad()
    try expectUI(engine.constellationResult?.id == previous && engine.constellationFocusIndex == 32 && engine.errorMessage != nil,
                 "failed layer load preserves displayed image and resets slider")
    try expectUI(!engine.isConnected && !engine.isFocuserConnected && !engine.isMountConnected, "recording review needs no connected devices")
}
