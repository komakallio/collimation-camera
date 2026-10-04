import Foundation

public enum ConstellationLayout: String, CaseIterable, Equatable, Codable, Sendable {
    case circular
    case rectangularGrid

    public var columnCount: Int { self == .circular ? 3 : 7 }
    public var rowCount: Int { self == .circular ? 3 : 5 }
    public var positionCount: Int { columnCount * rowCount }

    public static func forMosaic(width: Int, height: Int) -> Self? {
        let cell = CaptureLayout.stackingCropSize
        return allCases.first { width == $0.columnCount * cell && height == $0.rowCount * cell }
    }
}

/// One star placement in the constellation: sensor target and mosaic cell.
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

/// Circular sampling or a denser grid spanning the usable rectangular sensor field.
public enum ConstellationCapture {
    public static let gridSize = 3
    public static let positionCount = gridSize * gridSize
    public static let circleDiameterFraction = 0.80

    /// Centre first, then clockwise from north or alternating rectangular rows.
    public static func positions(sensorWidth: Int, sensorHeight: Int, layout: ConstellationLayout = .circular) -> [ConstellationPosition] {
        if layout == .rectangularGrid {
            return rectangularPositions(sensorWidth: sensorWidth, sensorHeight: sensorHeight, layout: layout)
        }
        let center = MountGuide.frameCenter(width: sensorWidth, height: sensorHeight)
        let radius = circleDiameterFraction / 2 * Double(max(sensorHeight, 1))
        let margin = Double(CaptureLayout.stackingCropSize) / 2
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

    /// Keep a full stacking crop inside every edge, including the four corners.
    /// After the centre, alternate row directions to avoid crossing the full field between rows.
    private static func rectangularPositions(sensorWidth: Int, sensorHeight: Int, layout: ConstellationLayout) -> [ConstellationPosition] {
        func coordinate(_ index: Int, count: Int, dimension: Int) -> Double {
            let last = Double(max(dimension, 1) - 1)
            let margin = min(Double(CaptureLayout.stackingCropSize) / 2, last / 2)
            return margin + (last - 2 * margin) * Double(index) / Double(count - 1)
        }
        let middleRow = layout.rowCount / 2, middleColumn = layout.columnCount / 2
        var result = [ConstellationPosition(label: "C", row: middleRow, column: middleColumn,
            sensorPoint: MountGuide.frameCenter(width: sensorWidth, height: sensorHeight))]
        for row in 0..<layout.rowCount {
            for offset in 0..<layout.columnCount {
                let column = row.isMultiple(of: 2) ? offset : layout.columnCount - 1 - offset
                if row == middleRow && column == middleColumn { continue }
                result.append(ConstellationPosition(label: "R\(row + 1)C\(column + 1)", row: row, column: column,
                    sensorPoint: SIMD2(coordinate(column, count: layout.columnCount, dimension: sensorWidth),
                                       coordinate(row, count: layout.rowCount, dimension: sensorHeight))))
            }
        }
        return result
    }

    /// Pack stacked tiles into their sensor layout. Missing cells stay zero.
    public static func mosaic(_ tiles: [(row: Int, column: Int, image: StackedImage)], layout: ConstellationLayout = .circular) throws -> StackedImage {
        guard let first = tiles.first else {
            throw CameraError.unsupported("No constellation tiles to combine.")
        }
        let cellWidth = first.image.width
        let cellHeight = first.image.height
        guard cellWidth > 0, cellHeight > 0 else {
            throw CameraError.unsupported("Constellation tiles are empty.")
        }
        for tile in tiles {
            guard tile.image.width == cellWidth, tile.image.height == cellHeight,
                  tile.image.pixels.count == cellWidth * cellHeight else {
                throw CameraError.unsupported("Constellation tiles must share the same size.")
            }
            guard (0..<layout.rowCount).contains(tile.row), (0..<layout.columnCount).contains(tile.column) else {
                throw CameraError.unsupported("Constellation tile is outside the \(layout.columnCount)×\(layout.rowCount) grid.")
            }
        }
        guard Set(tiles.map { $0.row * layout.columnCount + $0.column }).count == tiles.count else {
            throw CameraError.unsupported("Constellation tiles must occupy different cells.")
        }
        let width = cellWidth * layout.columnCount
        let height = cellHeight * layout.rowCount
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
