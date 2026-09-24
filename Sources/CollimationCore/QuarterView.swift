import Foundation

/// The live image folded across the star.
///
/// The top-left quadrant stays. The right-hand pair is swapped above and below,
/// and the lower pair is swapped left and right, so each seam joins quadrants
/// that did not originally touch. A left-right mismatch shows on the vertical
/// seam and an up-down mismatch on the horizontal one. The star still meets in
/// the middle. Tiles are clipped to the image, so an off-centre star is not
/// stretched.
public enum QuarterView {
    public struct Quad: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
        /// Texture coordinates of the tile's top-left and bottom-right. One or
        /// both axes run backwards when that quadrant is flipped.
        public var u0: Double
        public var v0: Double
        public var u1: Double
        public var v1: Double

        public init(
            x: Double,
            y: Double,
            width: Double,
            height: Double,
            u0: Double,
            v0: Double,
            u1: Double,
            v1: Double
        ) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.u0 = u0
            self.v0 = v0
            self.u1 = u1
            self.v1 = v1
        }
    }

    public static func quads(
        imageWidth: Int,
        imageHeight: Int,
        star: SIMD2<Double>,
        imageRect: (x: Double, y: Double, width: Double, height: Double)
    ) -> [Quad] {
        let width = Double(imageWidth)
        let height = Double(imageHeight)
        guard width > 1, height > 1, imageRect.width > 1, imageRect.height > 1 else { return [] }
        let starX = min(max(star.x, 0), width)
        let starY = min(max(star.y, 0), height)
        let scaleX = imageRect.width / width
        let scaleY = imageRect.height / height
        let starViewX = imageRect.x + starX * scaleX
        let starViewY = imageRect.y + starY * scaleY
        let roomLeft = starViewX - imageRect.x
        let roomRight = imageRect.x + imageRect.width - starViewX
        let roomUp = starViewY - imageRect.y
        let roomDown = imageRect.y + imageRect.height - starViewY

        // Top-left stays. The right pair swaps above and below, then the lower
        // pair swaps left and right, so neither seam joins quadrants that
        // originally touched.
        let placements: [(sx: Double, sy: Double, dx: Double, dy: Double)] = [
            (-1, -1, -1, -1),
            (1, 1, 1, -1),
            (1, -1, -1, 1),
            (-1, 1, 1, 1),
        ]
        return placements.compactMap { place in
            let extentX = place.sx < 0 ? starX : width - starX
            let extentY = place.sy < 0 ? starY : height - starY
            let roomX = place.dx < 0 ? roomLeft : roomRight
            let roomY = place.dy < 0 ? roomUp : roomDown
            let destW = min(extentX * scaleX, roomX)
            let destH = min(extentY * scaleY, roomY)
            guard destW > 0.5, destH > 0.5 else { return nil }
            let pixelsX = destW / scaleX
            let pixelsY = destH / scaleY
            let farX = starX + place.sx * pixelsX
            let farY = starY + place.sy * pixelsY
            let x = place.dx < 0 ? starViewX - destW : starViewX
            let y = place.dy < 0 ? starViewY - destH : starViewY
            let topIsFar = place.dy < 0
            let leftIsFar = place.dx < 0
            let uAt: (Bool) -> Double = { far in (far ? farX : starX) / width }
            let vAt: (Bool) -> Double = { far in (far ? farY : starY) / height }
            return Quad(
                x: x,
                y: y,
                width: destW,
                height: destH,
                u0: uAt(leftIsFar),
                v0: vAt(topIsFar),
                u1: uAt(!leftIsFar),
                v1: vAt(!topIsFar)
            )
        }
    }
}
