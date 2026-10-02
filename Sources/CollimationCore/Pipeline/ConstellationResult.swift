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
    public let sourceURL: URL
    public let histogram: Histogram
    public let tiltReport: TiltMeasurementReport?
    public let metadataWarning: String?

    public init(tiles: [ConstellationTile], sourceURL: URL, tiltReport: TiltMeasurementReport? = nil, metadataWarning: String? = nil) throws {
        let cell = CaptureLayout.stackingCropSize
        guard tiles.count == 9, Set(tiles.map { $0.row * 3 + $0.column }).count == 9,
              tiles.allSatisfy({
                  (0..<3).contains($0.row) && (0..<3).contains($0.column)
                      && $0.image.width == cell && $0.image.height == cell
                      && $0.image.pixels.count == cell * cell
                      && $0.image.pixels.allSatisfy { $0.isFinite && $0 >= 0 }
              }) else {
            throw CameraError.unsupported("A constellation must contain nine 256×256 float star images.")
        }
        self.tiles = tiles.sorted { $0.row * 3 + $0.column < $1.row * 3 + $1.column }
        self.sourceURL = sourceURL
        self.tiltReport = tiltReport
        self.metadataWarning = metadataWarning
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
        let document = try MonoTIFF.readConstellationWithMetadata(from: url)
        let mosaic = document.image
        let cell = CaptureLayout.stackingCropSize
        var tiles: [ConstellationTile] = []
        for row in 0..<3 {
            for column in 0..<3 {
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
        return try ConstellationResult(tiles: tiles, sourceURL: url, tiltReport: document.report, metadataWarning: document.warning)
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
