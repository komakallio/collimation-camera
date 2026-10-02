import CollimationCore
import CollimationUI
import Foundation

private func resultFixture() throws -> ConstellationResult {
    let side = 256
    let tiles = (0..<9).map { index in
        let center = SIMD2(100.25 + Double(index) * 3, 119.75 - Double(index))
        var pixels = [Float](repeating: 200.25 + Float(index), count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                let r = hypot(Double(x) - center.x, Double(y) - center.y)
                pixels[y * side + x] += Float(12000 * exp(-pow(r - 24, 2) / 8))
            }
        }
        return ConstellationTile(row: index / 3, column: index % 3, image: StackedImage(
            width: side, height: side, pixels: pixels, roi: ROI(x: 0, y: 0, width: side, height: side),
            referenceCentroid: center
        ))
    }
    return try ConstellationResult(tiles: tiles.reversed(), sourceURL: URL(fileURLWithPath: "fixture.tif"))
}

func testConstellationTIFFReading() throws {
    let result = try resultFixture()
    let mosaic = try ConstellationCapture.mosaic(result.tiles.map { ($0.row, $0.column, $0.image) })
    let data = try MonoTIFF.encode(floats: mosaic.pixels, width: 768, height: 768)
    let decoded = try MonoTIFF.decodeConstellation(data)
    try expectUI(decoded.pixels == mosaic.pixels, "float samples survive TIFF round trip exactly")
    try expectUI(decoded.pixels[0] == 200.25, "fractional ADU retained")
    func rejected(_ bytes: Data) throws {
        do { _ = try MonoTIFF.decodeConstellation(bytes) }
        catch { return }
        throw UIModelExpectation(description: "malformed TIFF accepted")
    }
    try rejected(Data(data.prefix(100)))
    var broken = data
    broken[4] = 255; broken[5] = 255; broken[6] = 255; broken[7] = 255
    try rejected(broken)
    broken = data
    let aboveRange = Float(65536.25).bitPattern
    for i in 0..<4 { broken[8 + i] = UInt8(truncatingIfNeeded: aboveRange >> (i * 8)) }
    try expectUI(try MonoTIFF.decodeConstellation(broken).pixels[0] == 65536.25, "over-range float saturation retained")
    broken = data
    let negative = Float(-1).bitPattern
    for i in 0..<4 { broken[8 + i] = UInt8(truncatingIfNeeded: negative >> (i * 8)) }
    try rejected(broken)
    broken = data
    broken[8] = 0; broken[9] = 0; broken[10] = 192; broken[11] = 127 // NaN first sample
    try rejected(broken)
    broken = data
    broken[0] = 77
    try rejected(broken)
    let ifd = 8 + 768 * 768 * 4
    broken = data
    broken[ifd + 2 + 3 * 12 + 8] = 5 // compression
    try rejected(broken)
    broken = data
    broken[ifd + 2 + 2 * 12 + 4] = 2 // array instead of scalar BitsPerSample
    try rejected(broken)
    try rejected(MonoTIFF.encode(pixels: [UInt16](repeating: 10, count: 768 * 768), width: 768, height: 768))
    try rejected(MonoTIFF.encode(floats: [Float](repeating: 10, count: 256 * 256), width: 256, height: 256))
    let accumulator = FrameStackAccumulator(frame: Frame(width: 1, height: 1, pixels: [5], roi: ROI(x: 0, y: 0, width: 1, height: 1)), centroid: SIMD2(0.25, 0.75))
    try expectUI(accumulator.finish().referenceCentroid == SIMD2(0.25, 0.75), "registration anchor retained")
}

func testConstellationCenteredZoom() throws {
    let result = try resultFixture()
    try expectUI(result.tiles.map { $0.row * 3 + $0.column } == Array(0..<9), "display order follows mosaic")
    try expectUI(result.histogram.sampleCount == 9 * 256 * 256, "histogram covers all full crops")
    try expectUI(result.histogram.bins.reduce(0, +) == UInt32(result.histogram.sampleCount), "histogram samples counted once")
    for size in [SIMD2(980.0, 796.0), SIMD2(480.0, 576.0), SIMD2(1960.0, 1592.0)] {
        let fitted = ConstellationScene.cells(result: result, size: size, zoom: 1)
        for zoom in [1.0, 2.0, 8.0] {
            let cells = ConstellationScene.cells(result: result, size: size, zoom: zoom)
            for (i, cell) in cells.enumerated() {
                try expectUI(cell.viewPoint(for: cell.tile.center) == cell.origin + cell.size / 2, "star anchor stays centred")
                try expectUI(abs(cell.scale - cells[0].scale) < 1e-12, "all nine share pixel scale")
                try expectUI(abs(cell.scale / fitted[i].scale - zoom) < 1e-12, "shared zoom multiplier")
                let sampledCenter = (cell.uvOrigin + cell.uvSize / 2) * SIMD2(256.0, 256.0) - SIMD2(repeating: 0.5)
                try expectUI(abs(sampledCenter.x - cell.tile.center.x) < 1e-9 && abs(sampledCenter.y - cell.tile.center.y) < 1e-9, "GPU UV anchors match geometry")
                if zoom == 1 {
                    try expectUI(cell.uvOrigin.x <= 0 && cell.uvOrigin.y <= 0, "fit includes top left")
                    try expectUI((cell.uvOrigin + cell.uvSize).x >= 1 && (cell.uvOrigin + cell.uvSize).y >= 1, "fit includes bottom right")
                }
            }
        }
    }
    let imported = ConstellationTile(row: 0, column: 0, image: StackedImage(width: 256, height: 256,
        pixels: result.tiles[0].image.pixels, roi: result.tiles[0].image.roi))
    try expectUI(imported.centerDetected && hypot(imported.center.x - 100.25, imported.center.y - 119.75) < 1, "off-centre donut detected on reopen")
    let empty = ConstellationTile(row: 0, column: 0, image: StackedImage(width: 256, height: 256,
        pixels: [Float](repeating: 0, count: 256 * 256), roi: result.tiles[0].image.roi))
    try expectUI(!empty.centerDetected && empty.center == SIMD2(127.5, 127.5), "missing star falls back to tile midpoint")
}

@MainActor
func testConstellationViewerState() async throws {
    let (engine, suite) = try makeTestEngine(suffix: "constellation")
    defer { engine.shutdown(); UserDefaults.standard.removePersistentDomain(forName: suite) }
    let result = try resultFixture()
    try expectUI(engine.canOpenConstellation && !engine.canShowConstellation, "open available without camera or result")
    let cameraStretch = engine.stretch
    engine.displayConstellation(result)
    engine.constellationZoom = 8
    engine.displayStretch.black = 0.005
    engine.displayStretch.curve = .arcsinh
    engine.autoStretchConstellation()
    try expectUI(engine.stretch == cameraStretch && engine.zoom == 1, "viewer controls leave camera settings intact")
    engine.showingConstellation = false
    engine.showingConstellation = true
    engine.disconnect()
    try expectUI(engine.constellationResult?.id == result.id && engine.constellationZoom == 8, "result survives switching and disconnect")
    let invalid = FileManager.default.temporaryDirectory.appendingPathComponent("invalid-constellation-\(UUID()).tif")
    defer { try? FileManager.default.removeItem(at: invalid) }
    try Data([0, 1, 2]).write(to: invalid)
    engine.openConstellation(from: invalid)
    let deadline = Date().addingTimeInterval(10)
    while engine.isLoadingConstellation && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    try expectUI(!engine.isLoadingConstellation && engine.errorMessage != nil, "failed load finishes and reports error")
    try expectUI(engine.constellationResult?.id == result.id && engine.constellationZoom == 8, "failed load preserves previous view")
    let valid = FileManager.default.temporaryDirectory.appendingPathComponent("valid-constellation-\(UUID()).tif")
    defer { try? FileManager.default.removeItem(at: valid) }
    let mosaic = try ConstellationCapture.mosaic(result.tiles.map { ($0.row, $0.column, $0.image) })
    try MonoTIFF.write(mosaic, to: valid)
    engine.openConstellation(from: valid)
    let loadDeadline = Date().addingTimeInterval(10)
    while engine.isLoadingConstellation && Date() < loadDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
    try expectUI(!engine.isLoadingConstellation && engine.constellationResult?.sourceURL == valid && engine.errorMessage == nil, "valid file replaces result asynchronously")
    engine.displayConstellation(result)
    try expectUI(engine.constellationZoom == 1 && engine.showingConstellation, "new result opens fitted")
}

@MainActor
func testConstellationMountIfRequested() async throws {
    guard let index = CommandLine.arguments.firstIndex(of: "--mount-port"), index + 1 < CommandLine.arguments.count else { return }
    let port = CommandLine.arguments[index + 1]
    let suite = "collimation-camera.tests.constellation-mount"
    guard let defaults = UserDefaults(suiteName: suite) else { throw UIModelExpectation(description: "mount test defaults") }
    let engine = CollimationEngine(defaults: defaults, serialPortPaths: { [port] })
    defer { engine.shutdown(); defaults.removePersistentDomain(forName: suite) }
    engine.selectedSerialPort = port
    engine.connectMount()
    let deadline = Date().addingTimeInterval(20)
    while engine.isMountBusy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    try expectUI(engine.isMountConnected, "mount connects on \(port): \(engine.errorMessage ?? engine.mountStatus)")
    let result = try resultFixture()
    engine.displayConstellation(result)
    engine.constellationZoom = 8
    engine.autoStretchConstellation()
    try expectUI(engine.isMountConnected && !engine.isMountBusy, "viewer does not start mount work")
    print("  Mount \(port): \(engine.mountStatus); results reviewed while connected")
}

func testSavedConstellationFiles() throws {
    guard let directory = ProcessInfo.processInfo.environment["COLLIMATION_CONSTELLATION_TEST_DIR"] else { return }
    let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.contains("constellation") && $0.pathExtension == "tif" }
    try expectUI(!files.isEmpty, "saved constellation fixtures found")
    var missingCenters = 0
    for file in files {
        let result = try ConstellationResult.load(from: file)
        try expectUI(result.tiles.count == 9, "nine tiles in \(file.lastPathComponent)")
        missingCenters += result.tiles.filter { !$0.centerDetected }.count
    }
    print("  Verified \(files.count) saved constellation TIFFs; \(missingCenters) cells used midpoint fallback")
}
