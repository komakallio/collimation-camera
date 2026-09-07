import Foundation

/// One star placement in the constellation: sensor target and 3×3 mosaic cell.
public struct ConstellationPosition: Equatable, Sendable {
    public var label: String
    /// Mosaic row, 0 = top.
    public var row: Int
    /// Mosaic column, 0 = left.
    public var column: Int
    public var sensorPoint: SIMD2<Double>

    public init(label: String, row: Int, column: Int, sensorPoint: SIMD2<Double>) {
        self.label = label
        self.row = row
        self.column = column
        self.sensorPoint = sensorPoint
    }
}

/// Center plus eight points on a circle whose diameter is 80% of the sensor height.
public enum ConstellationCapture {
    public static let gridSize = 3
    public static let positionCount = gridSize * gridSize
    public static let circleDiameterFraction = 0.80

    /// Capture order: center, then clockwise from north.
    public static func positions(sensorWidth: Int, sensorHeight: Int) -> [ConstellationPosition] {
        let center = MountGuide.frameCenter(width: sensorWidth, height: sensorHeight)
        let radius = circleDiameterFraction / 2 * Double(max(sensorHeight, 1))
        let margin = Double(CaptureLayout.displayCropSize) / 2
        func clamp(_ point: SIMD2<Double>) -> SIMD2<Double> {
            let maxX = max(margin, Double(max(sensorWidth, 1) - 1) - margin)
            let maxY = max(margin, Double(max(sensorHeight, 1) - 1) - margin)
            return SIMD2(
                min(max(point.x, min(margin, maxX)), maxX),
                min(max(point.y, min(margin, maxY)), maxY)
            )
        }
        let ring: [(String, Int, Int, Double)] = [
            ("N", 0, 1, -.pi / 2),
            ("NE", 0, 2, -.pi / 4),
            ("E", 1, 2, 0),
            ("SE", 2, 2, .pi / 4),
            ("S", 2, 1, .pi / 2),
            ("SW", 2, 0, 3 * .pi / 4),
            ("W", 1, 0, .pi),
            ("NW", 0, 0, -3 * .pi / 4)
        ]
        var result = [
            ConstellationPosition(label: "C", row: 1, column: 1, sensorPoint: clamp(center))
        ]
        result.reserveCapacity(positionCount)
        for (label, row, column, angle) in ring {
            let point = SIMD2(center.x + cos(angle) * radius, center.y + sin(angle) * radius)
            result.append(ConstellationPosition(label: label, row: row, column: column, sensorPoint: clamp(point)))
        }
        return result
    }

    /// Pack stacked tiles into a 3×3 mosaic. Missing cells stay zero.
    public static func mosaic(_ tiles: [(row: Int, column: Int, image: StackedImage)]) throws -> StackedImage {
        guard let first = tiles.first else {
            throw CameraError.unsupported("No constellation tiles to combine.")
        }
        let cellWidth = first.image.width
        let cellHeight = first.image.height
        guard cellWidth > 0, cellHeight > 0 else {
            throw CameraError.unsupported("Constellation tiles are empty.")
        }
        for tile in tiles {
            guard tile.image.width == cellWidth, tile.image.height == cellHeight else {
                throw CameraError.unsupported("Constellation tiles must share the same size.")
            }
            guard (0..<gridSize).contains(tile.row), (0..<gridSize).contains(tile.column) else {
                throw CameraError.unsupported("Constellation tile is outside the 3×3 grid.")
            }
        }
        let width = cellWidth * gridSize
        let height = cellHeight * gridSize
        var pixels = [Float](repeating: 0, count: width * height)
        for tile in tiles {
            let x0 = tile.column * cellWidth
            let y0 = tile.row * cellHeight
            let src = tile.image.pixels
            for y in 0..<cellHeight {
                let from = y * cellWidth
                let to = (y0 + y) * width + x0
                pixels.replaceSubrange(to..<(to + cellWidth), with: src[from..<(from + cellWidth)])
            }
        }
        return StackedImage(
            width: width,
            height: height,
            pixels: pixels,
            roi: ROI(x: 0, y: 0, width: width, height: height),
            timestamp: first.image.timestamp
        )
    }
}
