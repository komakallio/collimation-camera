import Foundation

public struct ConstellationTile: Sendable {
    public let row: Int
    public let column: Int
    public let image: StackedImage
    public let center: SIMD2<Double>
    public let centerDetected: Bool

    public init(row: Int, column: Int, image: StackedImage) {
        self.row = row
        self.column = column
        self.image = image
        let analysis = Frame(
            width: image.width, height: image.height,
            pixels: image.pixels.map { UInt16(min(max($0.isFinite ? $0.rounded() : 0, 0), 65535)) },
            roi: image.roi
        )
        let measured = image.referenceCentroid ?? StarDetector().detect(in: analysis)?.centroid
        if let measured, measured.x.isFinite, measured.y.isFinite,
           measured.x >= 0, measured.y >= 0,
           measured.x < Double(image.width), measured.y < Double(image.height) {
            center = measured
            centerDetected = true
        } else {
            center = SIMD2(Double(image.width - 1) / 2, Double(image.height - 1) / 2)
            centerDetected = false
        }
    }
}

/// Original ADU-valued float stacks; display changes never alter these pixels.
public struct ConstellationResult: Sendable {
    public let id = UUID()
    public let tiles: [ConstellationTile]
    public let layout: ConstellationLayout
    public let sourceURL: URL
    public let histogram: Histogram
    public let tiltReport: TiltMeasurementReport?
    public let metadataWarning: String?
    public let focusRecording: FocusConstellationRecording?
    public let focusIndex: Int

    public init(tiles: [ConstellationTile], sourceURL: URL, layout: ConstellationLayout = .circular, tiltReport: TiltMeasurementReport? = nil, metadataWarning: String? = nil, focusRecording: FocusConstellationRecording? = nil, focusIndex: Int = 0) throws {
        let cell = CaptureLayout.stackingCropSize
        guard tiles.count == layout.positionCount,
              focusRecording == nil || (focusRecording!.metadata.layout == layout && focusRecording!.metadata.positions.indices.contains(focusIndex)),
              Set(tiles.map { $0.row * layout.columnCount + $0.column }).count == layout.positionCount,
              tiltReport == nil || layout == .circular,
              tiles.allSatisfy({
                  (0..<layout.rowCount).contains($0.row) && (0..<layout.columnCount).contains($0.column)
                      && $0.image.width == cell && $0.image.height == cell
                      && $0.image.pixels.count == cell * cell
                      && $0.image.pixels.allSatisfy { $0.isFinite && $0 >= 0 }
              }) else {
            throw CameraError.unsupported("A constellation must contain \(layout.positionCount) 256×256 float star images in a \(layout.columnCount)×\(layout.rowCount) grid.")
        }
        self.layout = layout
        self.tiles = tiles.sorted { $0.row * layout.columnCount + $0.column < $1.row * layout.columnCount + $1.column }
        self.sourceURL = sourceURL
        self.tiltReport = tiltReport
        self.metadataWarning = metadataWarning
        self.focusRecording = focusRecording; self.focusIndex = focusIndex
        var bins = [UInt32](repeating: 0, count: Histogram.binCount)
        var peak: Float = 0
        var samples = 0
        for tile in tiles {
            if let point = tiltReport?.points.first(where: { $0.row == tile.row && $0.column == tile.column }), !point.imageCaptured { continue }
            samples += cell * cell
            for value in tile.image.pixels {
                bins[Int(min(value, 65535) / 256)] += 1
                peak = max(peak, value)
            }
        }
        histogram = Histogram(bins: bins, sampleCount: samples, maxADU: UInt16(min(peak.rounded(), 65535)))
    }

    public static func load(from url: URL) throws -> ConstellationResult {
        if let recording = try FocusConstellationRecording.openIfSupported(from: url) {
            return try recording.loadLayer(index: recording.metadata.positions.count / 2)
        }
        let document = try MonoTIFF.readConstellationWithMetadata(from: url)
        let mosaic = document.image
        guard let layout = ConstellationLayout.forMosaic(width: mosaic.width, height: mosaic.height) else {
            throw CameraError.unsupported("Unsupported constellation layout.")
        }
        let cell = CaptureLayout.stackingCropSize
        var tiles: [ConstellationTile] = []
        for row in 0..<layout.rowCount {
            for column in 0..<layout.columnCount {
                var pixels: [Float] = []
                pixels.reserveCapacity(cell * cell)
                for y in 0..<cell {
                    let start = (row * cell + y) * mosaic.width + column * cell
                    pixels.append(contentsOf: mosaic.pixels[start..<(start + cell)])
                }
                tiles.append(ConstellationTile(row: row, column: column, image: StackedImage(
                    width: cell, height: cell, pixels: pixels,
                    roi: ROI(x: 0, y: 0, width: cell, height: cell)
                )))
            }
        }
        let report = layout == .circular ? document.report : nil
        let warning = layout != .circular && document.report != nil
            ? "Tilt metadata does not match the constellation layout; the image is still available." : document.warning
        return try ConstellationResult(tiles: tiles, sourceURL: url, layout: layout, tiltReport: report, metadataWarning: warning)
    }
}

public struct ConstellationRenderState: Sendable {
    public var result: ConstellationResult?
    public var zoom: Double
    public var stretch: StretchParams

    public init(result: ConstellationResult? = nil, zoom: Double = 1, stretch: StretchParams = .default) {
        self.result = result
        self.zoom = zoom
        self.stretch = stretch
    }
}

/// Metal's draw callback reads a stable snapshot without accessing the actor.
public final class ConstellationRenderSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var state = ConstellationRenderState()
    public init() {}
    public func store(_ value: ConstellationRenderState) {
        lock.lock()
        state = value
        lock.unlock()
    }
    public func peek() -> ConstellationRenderState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }
}
