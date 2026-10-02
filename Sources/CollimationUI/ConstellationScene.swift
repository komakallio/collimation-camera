import CollimationCore
import Foundation

public struct ConstellationCell: Sendable {
    public let tile: ConstellationTile
    public let origin: SIMD2<Double>
    public let size: SIMD2<Double>
    public let scale: Double
    public var uvOrigin: SIMD2<Double> {
        (tile.center + SIMD2(repeating: 0.5) - size / (2 * scale)) / SIMD2(Double(tile.image.width), Double(tile.image.height))
    }
    public var uvSize: SIMD2<Double> {
        size / scale / SIMD2(Double(tile.image.width), Double(tile.image.height))
    }
    public func viewPoint(for pixel: SIMD2<Double>) -> SIMD2<Double> {
        origin + size / 2 + (pixel - tile.center) * scale
    }
}

/// Equal pixel scales, independently anchored stars, shared by both renderers.
public enum ConstellationScene {
    public static func cells(result: ConstellationResult, size: SIMD2<Double>, zoom: Double) -> [ConstellationCell] {
        let padding = 12.0, gap = 8.0, titleHeight = 28.0
        let side = max(1, min((size.x - 2 * padding - 2 * gap) / 3,
                              (size.y - 2 * padding - titleHeight - 2 * gap) / 3))
        let grid = SIMD2(repeating: 3 * side + 2 * gap)
        let start = SIMD2(max(padding, (size.x - grid.x) / 2),
                          padding + titleHeight + max(0, (size.y - 2 * padding - titleHeight - grid.y) / 2))
        var extent = 1.0
        for tile in result.tiles {
            extent = max(extent, tile.center.x + 0.5, Double(tile.image.width) - 0.5 - tile.center.x,
                         tile.center.y + 0.5, Double(tile.image.height) - 0.5 - tile.center.y)
        }
        let magnification = zoom.isFinite ? min(max(zoom, 1), 8) : 1
        let scale = side / (2 * extent) * magnification
        return result.tiles.map { tile in
            ConstellationCell(tile: tile,
                origin: start + SIMD2(Double(tile.column) * (side + gap), Double(tile.row) * (side + gap)),
                size: SIMD2(repeating: side), scale: scale)
        }
    }

    public static func primitives(state: ConstellationRenderState, size: SIMD2<Double>) -> [HUDPrimitive] {
        guard let result = state.result else {
            return [.text(SidebarText.constellationEmpty, at: size / 2, anchor: .center,
                          color: .systemGray, size: 14, monospaced: false, weight: .regular)]
        }
        var output: [HUDPrimitive] = [.clipped(origin: .zero, size: SIMD2(size.x, 34), cornerRadius: 0, primitives: [
            .text(result.sourceURL.lastPathComponent, at: SIMD2(12, 12), anchor: .topLeading,
                  color: .white, size: 13, monospaced: false, weight: .regular)
        ])]
        for cell in cells(result: result, size: size, zoom: state.zoom) {
            if !cell.tile.centerDetected {
                output.append(.clipped(origin: cell.origin, size: cell.size, cornerRadius: 0, primitives: [
                    .fillRect(origin: cell.origin, size: SIMD2(min(cell.size.x, 150), 24), color: .black.opacity(0.75), cornerRadius: 0),
                    .text(SidebarText.centerNotDetected, at: cell.origin + SIMD2(6, 6), anchor: .topLeading,
                          color: .systemYellow, size: 12, monospaced: false, weight: .regular)
                ]))
            }
            output.append(.rect(origin: cell.origin, size: cell.size, color: .systemGray.opacity(0.4), width: 1, cornerRadius: 0))
        }
        return output
    }
}
